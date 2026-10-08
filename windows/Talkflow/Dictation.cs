using System;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Talkflow.Core;
using Talkflow.Core.Text;

namespace Talkflow;

/// <summary>
/// The whole dictation pipeline (Dictation.swift). Runs on the UI thread.
///
/// While the shortcut is held, audio is captured and every 0.7 s the whole
/// buffer is transcribed and shown in the overlay caption. On release the
/// final transcript is rendered once, fully corrected, and typed into the
/// focused field in one go, so nothing is ever typed and then deleted.
///
/// With "type while speaking" on, the words that two transcripts agree on are
/// typed as you speak (StreamCommit), and the field is brought in line with
/// the final transcript at release, within a keystroke budget.
///
/// Nothing here may block the UI thread: the microphone opens and closes on
/// its own thread (Recorder), the screen is read in the background
/// (ScreenContext), and every request to the speech engine is awaited. Each
/// phase logs its steps with timings (StepLog), and every failure is said on
/// the pill instead of the dictation silently vanishing.
/// </summary>
sealed class Dictation
{
    readonly App _app;
    readonly Recorder _recorder = new();
    readonly StreamCommit _stream = new();
    readonly FieldSync _field = new();
    readonly DispatcherTimer _preview;
    readonly DispatcherTimer _watchdog;

    const double MinDuration = 0.3;
    /// <summary>How long the microphone keeps listening after release, for the last word still on its way.</summary>
    const int TailMs = 250;
    /// <summary>A preview slower than this pauses the live caption for the rest of the hold (a slow PC).</summary>
    const double PreviewBudgetSeconds = 2.5;

    bool _recording;
    DateTime? _startedAt;
    FocusTarget? _target;
    string _lastStreamed = "";
    bool _focusLeft;
    string _leadingSpace = "";
    bool _liveTyping;
    WritingStyle _style = WritingStyle.Formal;
    ScreenContext.Snapshot? _context;
    int _holdNumber;
    bool _previewInFlight;
    bool _previewsPaused;
    int _previews;
    double _slowestPreview;
    (string Text, string? Process)? _lastInsert;

    public bool IsRecording => _recording;

    public Dictation(App app)
    {
        _app = app;
        _recorder.Level += level => _app.Dispatcher.BeginInvoke(() => _app.Overlay.PushLevel(level));
        _recorder.Failed += message => _app.Dispatcher.BeginInvoke(() =>
        {
            if (!_recording) return;
            Abandon("the microphone could not be opened");
            _app.Overlay.ShowError("Could not use the microphone: " + message);
        });
        _preview = new DispatcherTimer(TimeSpan.FromSeconds(0.7), DispatcherPriority.Normal, (_, _) => TickPreview(), app.Dispatcher) { IsEnabled = false };
        // A key-up Windows never delivered (the lock screen) must not leave a hold running.
        _watchdog = new DispatcherTimer(TimeSpan.FromMilliseconds(250), DispatcherPriority.Normal, (_, _) =>
        {
            if (_recording && !_app.Hotkey.IsPhysicallyHeld()) Finish();
        }, app.Dispatcher) { IsEnabled = false };
    }

    public void Begin()
    {
        if (_recording) return;
        var steps = new StepLog("begin");
        steps.Next("microphone check");
        var microphone = Microphone.Check();
        if (microphone != Microphone.State.Allowed)
        {
            _app.Overlay.ShowError(Microphone.Describe(microphone));
            _app.ShowOnboarding();
            steps.End($"not recording: microphone {microphone}");
            return;
        }
        if (!SpeechEngine.Small.ModelIsComplete || !SpeechEngine.EngineInstalled)
        {
            _app.Overlay.ShowError("The speech engine isn't set up yet");
            _app.ShowOnboarding();
            steps.End("not recording: setup incomplete");
            return;
        }
        if (!_app.EngineReady)
        {
            // Recording now would end in a transcription that cannot happen.
            if (_app.EngineStarting)
            {
                _app.Overlay.ShowNotice("The speech engine is still starting. Try again in a moment.");
                steps.End("not recording: the engine is starting");
            }
            else
            {
                _app.Overlay.ShowError($"The speech engine is not running. {_app.EngineError} Starting it again...");
                _ = _app.StartEngine();
                steps.End($"not recording: the engine is not running ({_app.EngineError})");
            }
            return;
        }

        _recording = true;
        _startedAt = DateTime.UtcNow;
        _field.Reset();
        _stream.Reset();
        _lastStreamed = "";
        _focusLeft = false;
        _leadingSpace = "";
        _liveTyping = _app.Settings.TypeWhileSpeaking;
        _style = _app.Settings.WritingStyle;
        _previewsPaused = false;
        _previews = 0;
        _slowestPreview = 0;
        steps.Next("focus");
        _target = FocusTarget.Current();

        steps.Next("start recorder");
        _recorder.Start(); // returns at once; the device opens on the microphone thread
        steps.Next("tray");
        _app.Tray.SetState(TrayState.Recording);
        steps.Next("pill");
        _app.Overlay.Show();
        _preview.Start();
        _watchdog.Start();
        steps.Next("screen context");
        ReadContext();
        steps.End($"recording into {_target.ProcessName ?? "unknown"}" + (_liveTyping ? ", typing while speaking" : ""));
    }

    /// <summary>Ends a hold without inserting anything (another shortcut was pressed, or the microphone failed).</summary>
    public void Abandon() => Abandon("another key was pressed with the shortcut");

    void Abandon(string why)
    {
        if (!_recording) return;
        _recording = false;
        StopTimers();
        _ = _recorder.Stop();
        Dismiss();
        Log.Write($"hold abandoned: {why}");
    }

    public async void Finish()
    {
        if (!_recording) return;
        try
        {
            await FinishHold();
        }
        catch (Exception e)
        {
            // Whatever went wrong, the pill and tray must not stay in "writing".
            Log.Write($"finish failed: {e}");
            UiWatchdog.Step = "idle";
            Dismiss();
            _app.Overlay.ShowError("Something went wrong finishing this dictation: " + e.Message);
        }
    }

    async Task FinishHold()
    {
        var steps = new StepLog("finish");
        _recording = false;
        StopTimers();
        double duration = _startedAt is { } start ? (DateTime.UtcNow - start).TotalSeconds : 0;
        _startedAt = null;
        steps.Next("stop recorder");
        var capture = await _recorder.Stop(TailMs);
        var wav = capture.Wav;
        if (duration < MinDuration)
        {
            Dismiss();
            steps.End($"hold was {duration:F2}s, discarded as an accidental tap");
            return;
        }
        // Nothing to transcribe: the engine would only answer HTTP 400 to an
        // empty recording, which says nothing about the microphone.
        string microphone = capture.Device ?? "the microphone";
        if (capture.Buffers == 0)
        {
            Dismiss();
            _app.Overlay.ShowError($"No sound came from {microphone}. Check Settings > System > Sound > Input.");
            steps.End($"no audio from the microphone ({capture.Device ?? "unnamed"}) in {duration:F1}s, nothing sent to the engine");
            return;
        }
        if (capture.Peak == 0)
        {
            Dismiss();
            _app.Overlay.ShowError($"{microphone} sent only silence. It may be muted, or blocked in Privacy & security > Microphone.");
            steps.End($"only digital silence from the microphone ({capture.Device ?? "unnamed"}) in {duration:F1}s, nothing sent to the engine");
            return;
        }

        steps.Next("pill");
        _app.Tray.SetState(TrayState.Processing);
        _app.Overlay.ShowWorking();
        steps.Next("transcribe");
        var (result, failure) = await TranscribeFinal(wav, duration);
        if (result is null)
        {
            Dismiss();
            _app.Overlay.ShowError("Could not transcribe: " + (failure?.Message ?? "no answer"));
            if (failure?.EngineDown == true) _app.EngineLost();
            steps.End($"failed after {duration:F1}s of audio ({_previews} previews, slowest {_slowestPreview:F1}s): {failure?.Message}");
            return;
        }
        if (Transcript.IsPlaceholder(result.Text))
        {
            Dismiss();
            steps.End($"no speech in {duration:F1}s of audio");
            return;
        }

        steps.Next("render");
        var leading = _liveTyping ? _leadingSpace : LeadingSpaceFromContext();
        var final = Render.Text(result.Text, leading, structure: true, style: _style);
        var verbatim = Render.Text(result.Text, leading, structure: true, corrections: false, style: _style);
        Log.Write($"transcribed {Render.Shape(result.Text, result.Segments)} in {result.Elapsed:F2}s" + (Log.Transcripts ? ": " + result.Text : ""));

        var context = _context;
        if (!_liveTyping && ScreenText.ContinuesSentence(context?.TextBeforeCaret))
            final = ScreenText.LowercasingStart(final, Array.Empty<string>());
        if (ScreenText.IsChat(context?.ProcessName ?? _target?.ProcessName))
        {
            final = ScreenText.ChatStyled(final);
            verbatim = ScreenText.ChatStyled(verbatim);
        }

        if (!_liveTyping && _app.Settings.UseClaudePunctuation && ApiKeys.Has(ApiKeys.Provider.Anthropic))
        {
            steps.Next("Claude punctuation");
            var (polished, error) = await ClaudePolish.Run(final, _app.Settings.ClaudeModel, Array.Empty<string>());
            if (error is not null) _app.Overlay.ShowError(error);
            final = _style.Apply(polished);
        }
        steps.Next("deliver");
        var outcome = await Deliver(final, verbatim, duration);
        steps.End($"{duration:F1}s of audio, {_previews} previews (slowest {_slowestPreview:F1}s), {outcome}");
    }

    /// <summary>Types or copies the text; returns what happened, for the log.</summary>
    async Task<string> Deliver(string final, string verbatim, double duration)
    {
        string outcome;
        if (_liveTyping)
        {
            Reconcile(final, verbatim);
            outcome = _focusLeft ? "focus left the app, stopped typing" : "typed while speaking";
        }
        else if (Chars.Trim(final).Length > 0)
        {
            // Typing while the shortcut's keys are still down would send
            // Ctrl+letters. Wait (briefly) for the user to let go.
            var waited = System.Diagnostics.Stopwatch.StartNew();
            for (int i = 0; i < 100 && _app.Hotkey.AnyKeyHeld(); i++) await Task.Delay(50);
            if (waited.ElapsedMilliseconds > 100) Log.Write($"waited {waited.ElapsedMilliseconds} ms for the shortcut's keys to come up");
            var now = FocusTarget.Current();
            if (_app.Hotkey.AnyKeyHeld())
                outcome = ToClipboard(final, "a key of the shortcut was still held");
            else if (_target is null || !now.SameAppAs(_target) || now.IsTalkflow && !_app.IsTryItFocused)
                outcome = ToClipboard(final, "focus moved to another app");
            else if (now.IsElevatedAboveUs())
                outcome = ToClipboard(final, "that app runs as administrator, which blocks typing from other apps");
            else
            {
                SyncField(final);
                outcome = $"typed {Chars.Count(final)} characters into {now.ProcessName ?? "unknown"}";
            }
        }
        else
        {
            outcome = "nothing to type";
        }

        if (_field.TypedText.Length > 0)
        {
            _app.Stats.RecordSession(_field.TypedText, duration);
            _lastInsert = (_field.TypedText, _target?.ProcessName);
            ScheduleVocabularyCheck();
        }
        if (_recording && !_liveTyping) _field.Reset();
        _app.Overlay.Hide();
        KeyboardWriter.WhenDrained(() => _app.Dispatcher.BeginInvoke(() => { if (!_recording) _app.Tray.SetState(TrayState.Idle); }));
        return outcome;
    }

    string ToClipboard(string text, string why)
    {
        var trimmed = text.Trim(' ');
        for (int attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                Clipboard.SetText(trimmed);
                _app.Overlay.ShowNotice("Copied to the clipboard: press Ctrl+V to paste");
                return $"copied to the clipboard ({why})";
            }
            catch (System.Runtime.InteropServices.COMException)
            {
                System.Threading.Thread.Sleep(40);
            }
        }
        _app.Overlay.ShowError("Could not type or copy the dictation");
        return $"could not type ({why}) or copy it";
    }

    /// <summary>A space goes first when the caret sits right after a word.</summary>
    string LeadingSpaceFromContext()
    {
        var before = _context?.TextBeforeCaret;
        if (string.IsNullOrEmpty(before)) return "";
        char last = before[^1];
        return char.IsWhiteSpace(last) || "([{\"'“‘/-".Contains(last) ? "" : " ";
    }

    // MARK: - Transcription

    string Prompt => ScreenText.Prompt(Transcriber.VocabularyPrompt, Array.Empty<string>(), _app.Settings.LearnedWords);

    async Task<(Transcriber.Result? Result, Transcriber.Failure? Failure)> TranscribeFinal(byte[] wav, double duration)
    {
        var prompt = Prompt;
        if (_app.Settings.UseOpenAITranscription && ApiKeys.Has(ApiKeys.Provider.OpenAI))
        {
            var (result, error) = await CloudTranscriber.Transcribe(wav, prompt);
            if (result is not null)
            {
                Log.Write($"final pass via OpenAI {CloudTranscriber.Model} in {result.Elapsed:F2}s");
                return (result, null);
            }
            _app.Overlay.ShowError(error + ", used this PC instead");
        }
        if (_app.Settings.AccurateFinalPass && _app.FinalPassUsable)
        {
            // A budget, not a hang: past it, small.en answers instead.
            var budget = TimeSpan.FromSeconds(3 + 0.5 * duration);
            var (large, _) = await Transcriber.Transcribe(wav, SpeechEngine.Large.InferenceUrl, budget, prompt);
            if (large is not null)
            {
                Log.Write("final pass via large-v3-turbo");
                return (large, null);
            }
            Log.Write($"final-pass model did not answer within {budget.TotalSeconds:F1}s, falling back to small.en");
        }
        // Longer recordings take longer, most of all on a slow PC.
        return await Transcriber.Transcribe(wav, SpeechEngine.Small.InferenceUrl, TimeSpan.FromSeconds(20 + 2 * duration), prompt);
    }

    async void TickPreview()
    {
        if (!_recording || _previewInFlight || _previewsPaused || _recorder.DurationSeconds < 0.5) return;
        _previewInFlight = true;
        int hold = _holdNumber;
        // No short timeout: whisper-server finishes a request even after the
        // client gives up, so an abandoned preview would only queue the next
        // one, and the final text, behind it. One preview at a time, always
        // waited for.
        var (result, _) = await Transcriber.Transcribe(_recorder.SnapshotWav(), SpeechEngine.Small.InferenceUrl, TimeSpan.FromSeconds(120), Prompt);
        _previewInFlight = false;
        if (hold != _holdNumber) return;
        _previews++;
        if (result is not null)
        {
            _slowestPreview = Math.Max(_slowestPreview, result.Elapsed);
            if (result.Elapsed > PreviewBudgetSeconds && !_previewsPaused)
            {
                // The caption is a nicety; the final text must not wait behind it.
                _previewsPaused = true;
                Log.Write($"live caption paused for this hold: a preview took {result.Elapsed:F1}s");
            }
        }
        if (!_recording || result is null || Transcript.IsPlaceholder(result.Text)) return;
        var rendered = Render.Text(result.Text, _leadingSpace, structure: false, style: _style);
        if (!_liveTyping)
        {
            _stream.Advance(rendered);
            var (settled, pending) = Render.CaptionParts(_stream.Committed, rendered);
            _app.Overlay.ShowCaption(settled, pending);
            return;
        }
        if (_stream.Advance(rendered) is { } committed) StreamField(committed);
    }

    // MARK: - Context

    async void ReadContext()
    {
        _holdNumber++;
        _context = null;
        int hold = _holdNumber;
        var target = _target!;
        // talkflow's own window (the Try it box) is read directly: UI
        // Automation calls from a process into its own UI are a classic way
        // to deadlock, and are never needed.
        var snapshot = target.IsTalkflow ? _app.OwnFieldSnapshot() : await ScreenContext.CaptureAsync(target);
        if (_holdNumber != hold) return;
        _context = snapshot;
        if (_field.TypedText.Length == 0 && _lastStreamed.Length == 0) _leadingSpace = LeadingSpaceFromContext();
        Learn(snapshot);
    }

    /// <summary>A little after a dictation, reads the field again to learn words the user corrected.</summary>
    void ScheduleVocabularyCheck()
    {
        int hold = _holdNumber;
        // DispatcherTimer's constructor that takes a dispatcher throws on a
        // null callback, so the callback is passed here, not added later.
        DispatcherTimer? timer = null;
        timer = new DispatcherTimer(TimeSpan.FromSeconds(20), DispatcherPriority.Background, async (_, _) =>
        {
            timer!.Stop();
            if (_holdNumber != hold || _recording) return;
            var target = FocusTarget.Current();
            var snapshot = target.IsTalkflow ? _app.OwnFieldSnapshot() : await ScreenContext.CaptureAsync(target);
            Learn(snapshot);
        }, _app.Dispatcher);
        timer.Start();
    }

    void Learn(ScreenContext.Snapshot snapshot)
    {
        if (_lastInsert is not { } last || last.Process != snapshot.ProcessName || snapshot.FieldText is not { } text) return;
        var fixes = Vocabulary.Fixes(last.Text, text, word => SpellCheck.IsKnown(word) ?? true);
        if (fixes.Count == 0) return;
        _app.Settings.LearnedWords = Vocabulary.Remember(_app.Settings.LearnedWords, fixes);
        Log.Write($"learned {fixes.Count} word(s) from a correction");
    }

    // MARK: - Writing

    void Reconcile(string final, string verbatim)
    {
        if (final.StartsWith(_field.TypedText, StringComparison.Ordinal))
        {
            if (final != _field.TypedText) SyncField(final);
            return;
        }
        if (FieldEdit.AppendOnlyTarget(_field.TypedText, verbatim) is { } appended && appended != _field.TypedText) SyncField(appended);
        var (target, note) = Render.CorrectionTarget(_field.TypedText, final, verbatim);
        if (note is not null) Log.Write(note);
        if (target is not null) SyncField(target);
    }

    void StreamField(string desired)
    {
        if (!desired.StartsWith(_lastStreamed, StringComparison.Ordinal))
        {
            Log.Write("refused a live update that was not an append");
            return;
        }
        _lastStreamed = desired;
        SyncField(desired);
    }

    void SyncField(string desired)
    {
        if (_focusLeft) return;
        var now = FocusTarget.Current();
        if (_target is null || !now.SameAppAs(_target))
        {
            // Stop writing for the rest of the hold: retyping at wherever the
            // caret now is would duplicate the dictation.
            _focusLeft = true;
            Log.Write($"focus left the target app for {now.ProcessName ?? "another app"}, stopped writing for this hold");
            _field.Reset();
            return;
        }
        var (deleting, inserting) = _field.Sync(desired);
        Log.Write($"typed into {now.ProcessName ?? "unknown"} [-{deleting} +{Chars.Count(inserting)}]");
    }

    void StopTimers()
    {
        _preview.Stop();
        _watchdog.Stop();
    }

    void Dismiss()
    {
        _app.Tray.SetState(TrayState.Idle);
        _app.Overlay.Hide();
    }
}

/// <summary>Everything this hold has typed, character for character; a rewrite can never reach past it.</summary>
sealed class FieldSync
{
    public string TypedText { get; private set; } = "";

    public void Reset() => TypedText = "";

    public (int Deleting, string Inserting) Sync(string desired)
    {
        if (desired == TypedText) return (0, "");
        var edit = FieldEdit.Edit(TypedText, desired);
        KeyboardWriter.Rewrite(edit.Deleting, edit.Inserting);
        TypedText = desired;
        return edit;
    }
}
