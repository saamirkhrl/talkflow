using System;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace Talkflow;

/// <summary>
/// What is around the caret when a dictation starts, read through UI
/// Automation (ScreenContext.swift does the same with macOS Accessibility).
/// Local, read-only, never logged, kept for one hold, and never read from a
/// password field. Used to lowercase a dictation that continues a sentence
/// and, a little later, to learn a word the user corrected.
///
/// Every read is bounded: many apps answer UI Automation slowly or not at
/// all, so whatever is not back in time is simply left out.
/// </summary>
static class ScreenContext
{
    public sealed record Snapshot(string? ProcessName, string? TextBeforeCaret, string? FieldText);

    const int BeforeLimit = 300;
    const int FieldLimit = 4000;
    static readonly TimeSpan Budget = TimeSpan.FromMilliseconds(350);

    public static Snapshot Capture(FocusTarget target)
    {
        var read = Task.Run(() => Read(target.ProcessName));
        try
        {
            if (read.Wait(Budget)) return read.Result;
        }
        catch (AggregateException) { }
        return new Snapshot(target.ProcessName, null, null);
    }

    static Snapshot Read(string? processName)
    {
        try
        {
            var element = AutomationElement.FocusedElement;
            if (element is null) return new Snapshot(processName, null, null);
            if (element.Current.IsPassword) return new Snapshot(processName, null, null);

            if (element.TryGetCurrentPattern(TextPattern.Pattern, out var pattern) && pattern is TextPattern text)
            {
                string? before = null;
                var selection = text.GetSelection();
                if (selection.Length > 0)
                {
                    var range = text.DocumentRange.Clone();
                    range.MoveEndpointByRange(TextPatternRangeEndpoint.End, selection[0], TextPatternRangeEndpoint.Start);
                    var all = range.GetText(-1) ?? "";
                    before = all.Length > BeforeLimit ? all[^BeforeLimit..] : all;
                }
                var field = text.DocumentRange.GetText(-1) ?? "";
                return new Snapshot(processName, before, field.Length > FieldLimit ? field[^FieldLimit..] : field);
            }
            if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var valuePattern) && valuePattern is ValuePattern value)
            {
                var field = value.Current.Value ?? "";
                return new Snapshot(processName, null, field.Length > FieldLimit ? field[^FieldLimit..] : field);
            }
        }
        catch (Exception e) when (e is ElementNotAvailableException or InvalidOperationException or COMException or ArgumentException)
        {
        }
        return new Snapshot(processName, null, null);
    }
}

/// <summary>
/// The Windows spell checker (ISpellChecker, Windows 8 and later), standing in
/// for NSSpellChecker: a dictated word it knows was not misheard, and a word it
/// only accepts capitalised is a name.
/// </summary>
static class SpellCheck
{
    [ComImport, Guid("8E018A9D-2415-4677-BF08-794EA61F94BB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISpellCheckerFactory
    {
        [PreserveSig] int get_SupportedLanguages(out IntPtr value);
        [PreserveSig] int IsSupported([MarshalAs(UnmanagedType.LPWStr)] string languageTag, out int value);
        [PreserveSig] int CreateSpellChecker([MarshalAs(UnmanagedType.LPWStr)] string languageTag, out ISpellChecker value);
    }

    [ComImport, Guid("B6FD0B71-E2BC-4653-8D05-F197E412770B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISpellChecker
    {
        [PreserveSig] int get_LanguageTag(out IntPtr value);
        [PreserveSig] int Check([MarshalAs(UnmanagedType.LPWStr)] string text, out IEnumSpellingError value);
    }

    [ComImport, Guid("803E3BD4-2828-4410-8290-418D1D73C762"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IEnumSpellingError
    {
        [PreserveSig] int Next(out IntPtr value);
    }

    [ComImport, Guid("7AB36653-1796-484B-BDFA-E74F1DB7C1DC")]
    class SpellCheckerFactory { }

    static ISpellChecker? _checker;
    static bool _tried;
    static readonly object Gate = new();

    static ISpellChecker? Checker
    {
        get
        {
            if (_tried) return _checker;
            _tried = true;
            try
            {
                var factory = (ISpellCheckerFactory)new SpellCheckerFactory();
                foreach (var tag in new[] { "en-US", "en-GB", "en" })
                {
                    if (factory.IsSupported(tag, out var supported) == 0 && supported != 0 && factory.CreateSpellChecker(tag, out var checker) == 0)
                    {
                        _checker = checker;
                        break;
                    }
                }
            }
            catch (Exception e) when (e is COMException or InvalidCastException)
            {
                Log.Write("the Windows spell checker is not available");
            }
            return _checker;
        }
    }

    /// <summary>Whether the English dictionary accepts <paramref name="word"/>. Null when there is no spell checker.</summary>
    public static bool? IsKnown(string word)
    {
        lock (Gate)
        {
            var checker = Checker;
            if (checker is null || word.Length == 0) return null;
            try
            {
                if (checker.Check(word, out var errors) != 0) return null;
                int hr = errors.Next(out var error);
                if (error != IntPtr.Zero) Marshal.Release(error);
                Marshal.ReleaseComObject(errors);
                return hr != 0; // S_FALSE: no errors
            }
            catch (COMException)
            {
                return null;
            }
        }
    }
}
