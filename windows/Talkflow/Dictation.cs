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
    (string Text, string? Process)? _lastInsert;

    public bool IsRecording => _recording;

    public Dictation(App app)
    {
        _app = app;
        _recorder.Level += level => _app.Dispatcher.BeginInvoke(() => _app.Overlay.PushLevel(level));
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
        var microphone = Microphone.Check();
        if (microphone != Microphone.State.Allowed)
        {
            _app.Overlay.ShowError(Microphone.Describe(microphone));
            _app.ShowOnboarding();
            return;
        }
        if (!SpeechEngine.Small.ModelIsComplete || !SpeechEngine.EngineInstalled)
        {
            _app.Overlay.ShowError("The speech engine isn't set up yet");
            _app.ShowOnboarding();
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
        _target = FocusTarget.Current();

        try
        {
            _recorder.Start();
        }
        catch (Exception e)
        {
            Log.Write($"could not start recording: {e.Message}");
            _recording = false;
            _app.Overlay.ShowError("Could not use the microphone: " + e.Message);
            return;
        }
        _app.Tray.SetState(TrayState.Recording);
        _app.Overlay.Show();
        _preview.Start();
        _watchdog.Start();
        ReadContext();
        Log.Write("recording started");
    }

    /// <summary>Ends a hold without inserting anything (another shortcut was pressed).</summary>
    public void Abandon()
    {
        if (!_recording) return;
        _recording = false;
        StopTimers();
        _recorder.Stop();
        Dismiss();
        Log.Write("hold abandoned: another key was pressed with the shortcut");
    }

    public async void Finish()
    {
        if (!_recording) return;
        _recording = false;
        StopTimers();
        double duration = _startedAt is { } start ? (DateTime.UtcNow - start).TotalSeconds : 0;
        _startedAt = null;
        var wav = _recorder.Stop();
        if (duration < MinDuration)
        {
            Log.Write($"hold was {duration:F2}s, discarding as an accidental tap");
            Dismiss();
            return;
        }

        _app.Tray.SetState(TrayState.Processing);
        _app.Overlay.ShowWorking();
        var result = await TranscribeFinal(wav);
        if (result is null || Transcript.IsPlaceholder(result.Text))
        {
            if (result is not null) Log.Write($"no speech in {duration:F1}s of audio");
            Dismiss();
            return;
        }

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
            var (polished, error) = await ClaudePolish.Run(final, _app.Settings.ClaudeModel, Array.Empty<string>());
            if (error is not null) _app.Overlay.ShowError(error);
            final = _style.Apply(polished);
        }
        await Deliver(final, verbatim, duration);
    }

    async Task Deliver(string final, string verbatim, double duration)
    {
        if (_liveTyping)
        {
            Reconcile(final, verbatim);
        }
        else if (Chars.Trim(final).Length > 0)
        {
            // Typing while the shortcut's keys are still down would send
            // Ctrl+letters. Wait (briefly) for the user to let go.
            for (int i = 0; i < 30 && _app.Hotkey.AnyKeyHeld(); i++) await Task.Delay(50);
            var now = FocusTarget.Current();
            if (_target is null || !now.SameAppAs(_target) || now.IsTalkflow && !_app.IsTryItFocused)
            {
                ToClipboard(final, "focus moved to another app");
            }
            else if (now.IsElevatedAboveUs())
            {
                ToClipboard(final, "that app runs as administrator, which blocks typing from other apps");
            }
            else
            {
                SyncField(final);
            }
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
    }

    void ToClipboard(string text, string why)
    {
        var trimmed = text.Trim(' ');
        for (int attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                Clipboard.SetText(trimmed);
                _app.Overlay.ShowNotice("Copied to the clipboard: press Ctrl+V to paste");
                Log.Write($"could not type the dictation ({why}), put it on the clipboard instead");
                return;
            }
            catch (System.Runtime.InteropServices.COMException)
            {
                System.Threading.Thread.Sleep(40);
            }
        }
        _app.Overlay.ShowError("Could not type or copy the dictation");
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

    async Task<Transcriber.Result?> TranscribeFinal(byte[] wav)
    {
        var prompt = Prompt;
        if (_app.Settings.UseOpenAITranscription && ApiKeys.Has(ApiKeys.Provider.OpenAI))
        {
            var (result, error) = await CloudTranscriber.Transcribe(wav, prompt);
            if (result is not null)
            {
                Log.Write($"final pass via OpenAI {CloudTranscriber.Model} in {result.Elapsed:F2}s");
                return result;
            }
            _app.Overlay.ShowError(error + ", used this PC instead");
        }
        if (_app.Settings.AccurateFinalPass && _app.FinalPassReady)
        {
            var large = await Transcriber.Transcribe(wav, SpeechEngine.Large.InferenceUrl, TimeSpan.FromSeconds(8), prompt);
            if (large is not null)
            {
                Log.Write("final pass via large-v3-turbo");
                return large;
            }
            Log.Write("final-pass model did not answer, falling back to small.en");
        }
        return await Transcriber.Transcribe(wav, SpeechEngine.Small.InferenceUrl, TimeSpan.FromSeconds(20), prompt);
    }

    async void TickPreview()
    {
        if (!_recording || _previewInFlight || _recorder.DurationSeconds < 0.5) return;
        _previewInFlight = true;
        var result = await Transcriber.Transcribe(_recorder.SnapshotWav(), SpeechEngine.Small.InferenceUrl, TimeSpan.FromSeconds(5), Prompt);
        _previewInFlight = false;
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

    void ReadContext()
    {
        _holdNumber++;
        _context = null;
        int hold = _holdNumber;
        var target = _target!;
        Task.Run(() => ScreenContext.Capture(target)).ContinueWith(task =>
        {
            if (_holdNumber != hold) return;
            _context = task.Result;
            if (_field.TypedText.Length == 0 && _lastStreamed.Length == 0) _leadingSpace = LeadingSpaceFromContext();
            Learn(task.Result);
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    void ScheduleVocabularyCheck()
    {
        int hold = _holdNumber;
        var timer = new DispatcherTimer(TimeSpan.FromSeconds(20), DispatcherPriority.Background, null, _app.Dispatcher);
        timer.Tick += async (_, _) =>
        {
            timer.Stop();
            if (_holdNumber != hold || _recording) return;
            var target = FocusTarget.Current();
            var snapshot = await Task.Run(() => ScreenContext.Capture(target));
            Learn(snapshot);
        };
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
