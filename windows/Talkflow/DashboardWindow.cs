using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using Talkflow.Core;
using Talkflow.Core.Text;

namespace Talkflow;

/// <summary>
/// Dashboard and Settings in one window (Dashboard.swift): stats from
/// stats.json, a 26-week chart, and every setting. Settings take effect from
/// the next hold.
/// </summary>
sealed class DashboardWindow : Window
{
    const int ChartWeeks = 26;
    const double Cell = 18, Tile = 14, AxisWidth = 30, MonthHeight = 16;

    readonly App _app;
    readonly ContentControl _page = new();
    readonly StackPanel _updateArea = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
    readonly Button _dashboardTab, _settingsTab;
    bool _showingSettings;

    public DashboardWindow(App app)
    {
        _app = app;
        Title = "talkflow";
        Ui.Style(this, 600, 700);

        var header = new Grid { Margin = new Thickness(0, 0, 0, 20) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var brand = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        brand.Children.Add(new Image { Source = Ui.AppIcon, Width = 40, Height = 40, Margin = new Thickness(0, 0, 12, 0) });
        var name = Ui.Numeral("talkflow", 28);
        name.VerticalAlignment = VerticalAlignment.Center;
        brand.Children.Add(name);
        header.Children.Add(brand);

        _dashboardTab = Ui.Button("Dashboard", () => ShowPage(false));
        _settingsTab = Ui.Button("Settings", () => ShowPage(true));
        var tabs = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0) };
        tabs.Children.Add(_dashboardTab);
        _settingsTab.Margin = new Thickness(4, 0, 0, 0);
        tabs.Children.Add(_settingsTab);
        var right = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        right.Children.Add(_updateArea);
        right.Children.Add(tabs);
        Grid.SetColumn(right, 2);
        header.Children.Add(right);

        var root = new DockPanel { Margin = new Thickness(28, 24, 28, 20) };
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);
        root.Children.Add(_page);
        Content = root;

        _app.Updater.Changed += OnUpdaterChanged;
        Closed += (_, _) => _app.Updater.Changed -= OnUpdaterChanged;
        RenderUpdate();
    }

    void OnUpdaterChanged() => Dispatcher.BeginInvoke(RenderUpdate);

    public void ShowPage(bool settings)
    {
        _showingSettings = settings;
        foreach (var (tab, selected) in new[] { (_dashboardTab, !settings), (_settingsTab, settings) })
        {
            tab.Background = selected ? Ui.Ink : Brushes.Transparent;
            tab.Foreground = selected ? Ui.Paper : Ui.Ink;
        }
        _app.Stats.Reload();
        _page.Content = settings ? BuildSettings() : BuildDashboard();
    }

    // MARK: - Update status

    void RenderUpdate()
    {
        _updateArea.Children.Clear();
        var version = Ui.Text(Updater.DisplayVersion, 11, Ui.Graphite, wrap: false);
        if (Updater.IsDevelopmentBuild) version.ToolTip = "A test build, not a release. Any release counts as newer.";
        version.Margin = new Thickness(0, 0, 8, 0);
        version.VerticalAlignment = VerticalAlignment.Center;
        var updater = _app.Updater;
        switch (updater.State)
        {
            case Updater.Phase.Checking:
                _updateArea.Children.Add(version);
                _updateArea.Children.Add(Ui.Text("Checking...", 11, Ui.Graphite, wrap: false));
                break;
            case Updater.Phase.Available when updater.Available is { } release:
                var button = Ui.Button($"Update to {release.Version}", _app.InstallUpdate, primary: true);
                button.ToolTip = $"Downloads {release.Version}, installs it and restarts talkflow. Your settings and stats stay.";
                _updateArea.Children.Add(button);
                break;
            case Updater.Phase.Downloading:
                _updateArea.Children.Add(Ui.Text("Downloading update...", 11, Ui.Graphite, wrap: false));
                break;
            case Updater.Phase.Installing:
                _updateArea.Children.Add(Ui.Text("Installing...", 11, Ui.Graphite, wrap: false));
                break;
            case Updater.Phase.Failed:
                var error = Ui.Text(updater.Error ?? "Update check failed", 11, Ui.Bad, wrap: false);
                error.MaxWidth = 220;
                error.TextTrimming = TextTrimming.CharacterEllipsis;
                error.ToolTip = updater.Error;
                error.Margin = new Thickness(0, 0, 8, 0);
                _updateArea.Children.Add(error);
                _updateArea.Children.Add(Link("Retry", () => _ = updater.Check()));
                break;
            default:
                _updateArea.Children.Add(version);
                var check = Link(updater.State == Updater.Phase.UpToDate ? updater.UpToDateText : "Check for updates", () => _ = updater.Check());
                check.ToolTip = "Check again";
                _updateArea.Children.Add(check);
                break;
        }
    }

    static TextBlock Link(string text, Action onClick)
    {
        var link = Ui.Text(text, 11, Ui.Ink, wrap: false);
        link.TextDecorations = TextDecorations.Underline;
        link.Cursor = Cursors.Hand;
        link.VerticalAlignment = VerticalAlignment.Center;
        link.MouseLeftButtonUp += (_, _) => onClick();
        return link;
    }

    // MARK: - Dashboard

    UIElement BuildDashboard()
    {
        var s = _app.Stats.Take();
        var panel = new StackPanel();

        panel.Children.Add(Ui.Text("Total words dictated", 13, Ui.Graphite));
        panel.Children.Add(Ui.Numeral(s.TotalWords.ToString("N0", CultureInfo.CurrentCulture), 64));
        var pages = Ui.Text($"about {(s.TotalWords / 500).ToString("N0", CultureInfo.CurrentCulture)} pages", 12, Ui.Graphite);
        pages.Margin = new Thickness(0, 0, 0, 20);
        panel.Children.Add(pages);

        var tiles = new (string Label, List<(string Value, string Unit)> Parts)[]
        {
            ("Words today", new() { (s.TodayWords.ToString("N0", CultureInfo.CurrentCulture), "") }),
            ("Speed", new() { (s.AverageWpm.ToString(CultureInfo.CurrentCulture), "wpm") }),
            ("Day streak", new() { (s.DayStreak.ToString(CultureInfo.CurrentCulture), s.DayStreak == 1 ? "day" : "days") }),
            ("Time saved", StatsStore.TimeSavedParts(s.EstimatedMinutesSaved)),
            ("Dictations", new() { (s.TotalSessions.ToString("N0", CultureInfo.CurrentCulture), "") }),
        };
        var grid = new UniformGrid { Columns = 3 };
        foreach (var tile in tiles)
        {
            var cell = new StackPanel();
            cell.Children.Add(Ui.Text(tile.Label, 12, Ui.Graphite));
            var value = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
            foreach (var part in tile.Parts)
            {
                value.Children.Add(Ui.Numeral(part.Value, 28));
                if (part.Unit.Length > 0)
                {
                    var unit = Ui.Text(part.Unit, 12, Ui.Graphite, wrap: false);
                    unit.VerticalAlignment = VerticalAlignment.Bottom;
                    unit.Margin = new Thickness(4, 0, 6, 6);
                    value.Children.Add(unit);
                }
            }
            cell.Children.Add(value);
            grid.Children.Add(new Border { BorderBrush = Ui.Line, BorderThickness = new Thickness(0.5), Padding = new Thickness(16), Child = cell });
        }
        panel.Children.Add(Ui.Card(grid, new Thickness(0)));

        var chartHeader = new DockPanel { Margin = new Thickness(0, 22, 0, 8) };
        var chartChoice = new ComboBox { Width = 120, FontSize = 12 };
        chartChoice.Items.Add("Grid");
        chartChoice.Items.Add("Weekly bars");
        chartChoice.SelectedItem = _app.Settings.DashboardChart;
        DockPanel.SetDock(chartChoice, Dock.Right);
        chartHeader.Children.Add(chartChoice);
        chartHeader.Children.Add(Ui.Text($"Last {ChartWeeks} weeks", 12, Ui.Graphite));
        panel.Children.Add(chartHeader);

        var chartHost = new ContentControl();
        var days = _app.Stats.RecentDays(ChartDays());
        chartHost.Content = _app.Settings.DashboardChart == "Weekly bars" ? WeeklyBars(days) : ContributionGrid(days);
        chartChoice.SelectionChanged += (_, _) =>
        {
            _app.Settings.DashboardChart = (string)chartChoice.SelectedItem;
            chartHost.Content = _app.Settings.DashboardChart == "Weekly bars" ? WeeklyBars(days) : ContributionGrid(days);
        };
        panel.Children.Add(chartHost);

        var hint = Ui.Text($"Hold {_app.Hotkey.Spec.Describe()} to dictate.", 12, Ui.Graphite);
        hint.Margin = new Thickness(0, 18, 0, 0);
        panel.Children.Add(hint);
        return new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    /// <summary>Enough days to fill the columns, the last one running up to today.</summary>
    static int ChartDays()
    {
        int sinceWeekStart = ((int)DateTime.Now.DayOfWeek - (int)CultureInfo.CurrentCulture.DateTimeFormat.FirstDayOfWeek + 7) % 7;
        return (ChartWeeks - 1) * 7 + sinceWeekStart + 1;
    }

    static double Shade(long words, long peak) => words == 0 ? 0.06 : 0.2 + 0.8 * Math.Min(1, (double)words / peak);

    static string Plural(long n) => n == 1 ? "word" : "words";

    UIElement ContributionGrid(List<(DateTime Date, long Words)> days)
    {
        long peak = Math.Max(days.Count == 0 ? 0 : days.Max(d => d.Words), 1);
        int weeks = (days.Count + 6) / 7;
        var canvas = new Canvas { Width = AxisWidth + weeks * Cell, Height = MonthHeight + 7 * Cell, HorizontalAlignment = HorizontalAlignment.Left };
        string? lastMonth = null;
        for (int w = 0; w < weeks; w++)
        {
            var month = days[w * 7].Date.ToString("MMM", CultureInfo.CurrentCulture);
            if (month != lastMonth && w < weeks - 1)
            {
                var label = Ui.Text(month, 10, Ui.Graphite, wrap: false);
                Canvas.SetLeft(label, AxisWidth + w * Cell + 2);
                canvas.Children.Add(label);
                lastMonth = month;
            }
        }
        for (int row = 1; row < 7; row += 2)
        {
            var label = Ui.Text(days.Count > row ? days[row].Date.ToString("ddd", CultureInfo.CurrentCulture) : "", 10, Ui.Graphite, wrap: false);
            Canvas.SetTop(label, MonthHeight + row * Cell + 1);
            canvas.Children.Add(label);
        }
        for (int i = 0; i < days.Count; i++)
        {
            var day = days[i];
            bool today = day.Date.Date == DateTime.Now.Date;
            var rect = new Rectangle
            {
                Width = Tile, Height = Tile, RadiusX = 3, RadiusY = 3,
                Fill = Ui.Ink_(Shade(day.Words, peak)),
                Stroke = today ? Ui.Ink : null,
                StrokeThickness = 1.5,
                ToolTip = $"{day.Date.ToString("ddd, MMM d", CultureInfo.CurrentCulture)}: {day.Words.ToString("N0", CultureInfo.CurrentCulture)} {Plural(day.Words)}",
            };
            Canvas.SetLeft(rect, AxisWidth + (i / 7) * Cell + 2);
            Canvas.SetTop(rect, MonthHeight + (i % 7) * Cell + 2);
            canvas.Children.Add(rect);
        }
        return canvas;
    }

    UIElement WeeklyBars(List<(DateTime Date, long Words)> days)
    {
        var weeks = Enumerable.Range(0, (days.Count + 6) / 7).Select(w => days.Skip(w * 7).Take(7).ToList()).ToList();
        var totals = weeks.Select(w => w.Sum(d => d.Words)).ToList();
        long peak = Math.Max(totals.Count == 0 ? 0 : totals.Max(), 1);
        double plotTop = 8, plotHeight = 7 * Cell - plotTop, baseline = plotTop + plotHeight;
        var canvas = new Canvas { Width = AxisWidth + weeks.Count * Cell, Height = MonthHeight + 7 * Cell, HorizontalAlignment = HorizontalAlignment.Left };
        var top = new Rectangle { Width = weeks.Count * Cell, Height = 0.5, Fill = Ui.Line };
        Canvas.SetLeft(top, AxisWidth); Canvas.SetTop(top, plotTop);
        canvas.Children.Add(top);
        var bottom = new Rectangle { Width = weeks.Count * Cell, Height = 1, Fill = Ui.Line };
        Canvas.SetLeft(bottom, AxisWidth); Canvas.SetTop(bottom, baseline);
        canvas.Children.Add(bottom);
        var peakLabel = Ui.Text(Compact(peak), 10, Ui.Graphite, wrap: false);
        Canvas.SetTop(peakLabel, plotTop - 7);
        canvas.Children.Add(peakLabel);
        var zero = Ui.Text("0", 10, Ui.Graphite, wrap: false);
        Canvas.SetTop(zero, baseline - 8);
        canvas.Children.Add(zero);
        for (int i = 0; i < weeks.Count; i++)
        {
            double height = totals[i] == 0 ? 0 : Math.Max(2, plotHeight * totals[i] / peak);
            var bar = new Rectangle
            {
                Width = Cell - 4, Height = height, RadiusX = 2, RadiusY = 2, Fill = Ui.Ink_(0.8),
                ToolTip = $"{weeks[i][0].Date.ToString("MMM d", CultureInfo.CurrentCulture)} - {weeks[i][^1].Date.ToString("MMM d", CultureInfo.CurrentCulture)}: {totals[i].ToString("N0", CultureInfo.CurrentCulture)} words",
            };
            Canvas.SetLeft(bar, AxisWidth + i * Cell + 2);
            Canvas.SetTop(bar, baseline - height);
            canvas.Children.Add(bar);
        }
        return canvas;
    }

    static string Compact(long n) => n >= 1000 ? (n / 1000.0).ToString("0.#", CultureInfo.CurrentCulture) + "k" : n.ToString(CultureInfo.CurrentCulture);

    // MARK: - Settings

    UIElement BuildSettings()
    {
        var settings = _app.Settings;
        var panel = new StackPanel { Margin = new Thickness(0, 4, 8, 4) };

        // Writing style
        var styles = new StackPanel { Orientation = Orientation.Horizontal };
        TextBlock? styleDetail = null;
        var styleButtons = new List<(Button Button, WritingStyle Style)>();
        foreach (var style in WritingStyles.All)
        {
            var button = Ui.Button(style.Title(), () => { });
            button.Margin = new Thickness(4, 0, 0, 0);
            styleButtons.Add((button, style));
            styles.Children.Add(button);
        }
        void PaintStyles()
        {
            foreach (var (button, style) in styleButtons)
            {
                bool on = settings.WritingStyle == style;
                button.Background = on ? Ui.Ink : Brushes.Transparent;
                button.Foreground = on ? Ui.Paper : Ui.Ink;
            }
            if (styleDetail is not null)
            {
                styleDetail.Text = settings.WritingStyle.Detail();
                styleDetail.Visibility = Visibility.Visible;
            }
        }
        foreach (var (button, style) in styleButtons)
            button.Click += (_, _) => { settings.WritingStyle = style; PaintStyles(); _app.Tray.Refresh(); };
        panel.Children.Add(Ui.Row("Writing style", "", styles, out styleDetail));
        PaintStyles();

        // Shortcut
        panel.Children.Add(ShortcutRow());

        // Models in use
        panel.Children.Add(ModelsInUse());

        panel.Children.Add(Ui.Row("Type while speaking",
            "Type words as you speak instead of when you let go.",
            Ui.Switch(settings.TypeWhileSpeaking, on => settings.TypeWhileSpeaking = on)));
        panel.Children.Add(Ui.Row("Accurate final pass",
            SpeechEngine.Large.ModelIsComplete
                ? "More accurate, a little slower."
                : "More accurate, a little slower. Downloads 574 MB once.",
            Ui.Switch(settings.AccurateFinalPass, on => { settings.AccurateFinalPass = on; if (on) _app.StartFinalPass(); })));
        panel.Children.Add(Ui.Row("Start with Windows",
            "",
            Ui.Switch(StartupEntry.IsEnabled, StartupEntry.Set)));

        panel.Children.Add(ApiKeysSection());
        panel.Children.Add(LearnedWords());

        var openFolder = Ui.Button("Open folder", () =>
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{Paths.DataDir}\"") { UseShellExecute = true }));
        panel.Children.Add(Ui.Row("Your data",
            "Stats, settings and learned words. Kept if you uninstall.",
            openFolder));

        panel.Children.Add(Ui.Row("Report a problem",
            "Saves a zip to your Desktop with talkflow's version, setup checks, settings switches and recent logs, to attach to an issue or an email. It never includes what you dictated, your learned words or API keys.",
            Ui.Button("Save diagnostics", _app.ReportProblem)));

        var uninstall = Ui.Button("Uninstall...", ConfirmUninstall);
        panel.Children.Add(Ui.Row("Uninstall talkflow",
            "Removes talkflow, its speech models, keys and logs. Your data stays.",
            uninstall));

        return new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    FrameworkElement ShortcutRow()
    {
        var current = Ui.Text(_app.Hotkey.Spec.Describe(), 12, Ui.Ink, FontWeights.SemiBold, wrap: false);
        current.VerticalAlignment = VerticalAlignment.Center;
        current.Margin = new Thickness(0, 0, 8, 0);
        var presets = new ComboBox { FontSize = 12, Width = 120 };
        foreach (var preset in HotkeySpec.Presets) presets.Items.Add(preset.Name);
        presets.SelectedIndex = Array.FindIndex(HotkeySpec.Presets, p => p.Spec.Equals(_app.Hotkey.Spec));
        presets.SelectionChanged += (_, _) =>
        {
            if (presets.SelectedIndex < 0) return;
            _app.SetHotkey(HotkeySpec.Presets[presets.SelectedIndex].Spec);
            current.Text = _app.Hotkey.Spec.Describe();
        };
        Button? record = null;
        record = Ui.Button("Record...", () =>
        {
            record!.Content = "Press keys...";
            _app.RecordHotkey(spec =>
            {
                record.Content = "Record...";
                if (spec is not null)
                {
                    _app.SetHotkey(spec);
                    current.Text = spec.Describe();
                    presets.SelectedIndex = Array.FindIndex(HotkeySpec.Presets, p => p.Spec.Equals(spec));
                }
            });
        });
        record.Margin = new Thickness(6, 0, 0, 0);
        var controls = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top };
        controls.Children.Add(current);
        controls.Children.Add(presets);
        controls.Children.Add(record);
        return Ui.Row("Shortcut", "", controls);
    }

    FrameworkElement ModelsInUse()
    {
        var settings = _app.Settings;
        string local = _app.FinalPassReady && settings.AccurateFinalPass ? "Whisper large-v3-turbo, on this PC" : "Whisper small.en, on this PC";
        string final = settings.UseOpenAITranscription && ApiKeys.Has(ApiKeys.Provider.OpenAI) ? $"OpenAI {CloudTranscriber.Model}, your key" : local;
        string punctuation = settings.UseClaudePunctuation && ApiKeys.Has(ApiKeys.Provider.Anthropic)
            ? SettingsStore.ClaudeModels.First(m => m.Id == settings.ClaudeModel).Title + ", your key"
            : "Built-in rules only";
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(100) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        var rows = new[] { ("Live caption", "Whisper small.en, on this PC"), ("Final text", final), ("Punctuation", punctuation) };
        for (int i = 0; i < rows.Length; i++)
        {
            grid.RowDefinitions.Add(new RowDefinition());
            var role = Ui.Text(rows[i].Item1, 12, Ui.Graphite);
            var model = Ui.Text(rows[i].Item2, 12, Ui.Ink, FontWeights.SemiBold);
            Grid.SetRow(role, i);
            Grid.SetRow(model, i);
            Grid.SetColumn(model, 1);
            grid.Children.Add(role);
            grid.Children.Add(model);
        }
        var stack = new StackPanel();
        var title = Ui.Title("Models in use");
        title.Margin = new Thickness(0, 0, 0, 6);
        stack.Children.Add(title);
        stack.Children.Add(grid);
        var card = Ui.Card(stack);
        card.Margin = new Thickness(0, 0, 0, 18);
        return card;
    }

    FrameworkElement ApiKeysSection()
    {
        var settings = _app.Settings;
        var panel = new StackPanel { Margin = new Thickness(0, 0, 0, 18) };
        panel.Children.Add(Ui.Title("Your own API keys"));
        var intro = Ui.Detail("Optional. Stored in Credential Manager and billed to your account.");
        intro.Margin = new Thickness(0, 4, 0, 12);
        panel.Children.Add(intro);

        panel.Children.Add(KeyRow(ApiKeys.Provider.OpenAI, "sk-..."));
        panel.Children.Add(Ui.Row("Use my OpenAI key for transcription",
            $"{CloudTranscriber.Model} writes the final text.",
            Gate(Ui.Switch(settings.UseOpenAITranscription, on => settings.UseOpenAITranscription = on), ApiKeys.Provider.OpenAI)));
        panel.Children.Add(KeyRow(ApiKeys.Provider.Anthropic, "sk-ant-..."));
        panel.Children.Add(Ui.Row("Use my Anthropic key for punctuation",
            "Claude fixes punctuation. Never changes your words.",
            Gate(Ui.Switch(settings.UseClaudePunctuation, on => settings.UseClaudePunctuation = on), ApiKeys.Provider.Anthropic)));
        var models = new ComboBox { FontSize = 12, Width = 200 };
        foreach (var model in SettingsStore.ClaudeModels) models.Items.Add(model.Title);
        models.SelectedIndex = Array.FindIndex(SettingsStore.ClaudeModels, m => m.Id == settings.ClaudeModel);
        models.SelectionChanged += (_, _) => { if (models.SelectedIndex >= 0) settings.ClaudeModel = SettingsStore.ClaudeModels[models.SelectedIndex].Id; };
        panel.Children.Add(Ui.Row("Claude model", "", Gate(models, ApiKeys.Provider.Anthropic)));
        return panel;
    }

    static UIElement Gate(Control control, ApiKeys.Provider provider)
    {
        control.IsEnabled = ApiKeys.Has(provider);
        return control;
    }

    FrameworkElement KeyRow(ApiKeys.Provider provider, string placeholder)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 0, 0, 12) };
        var row = new DockPanel();
        var label = Ui.Text(ApiKeys.Name(provider), 12, Ui.Ink, FontWeights.SemiBold, wrap: false);
        label.Width = 80;
        label.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(label, Dock.Left);
        row.Children.Add(label);
        var status = Ui.Text("", 11, Ui.Graphite);
        status.Margin = new Thickness(80, 4, 0, 0);

        var field = Ui.SecretField();
        field.ToolTip = ApiKeys.Has(provider) ? "Saved" : placeholder;
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(6, 0, 0, 0) };
        Button? use = null;
        use = Ui.Button("Use key", async () =>
        {
            var draft = field.Password.Trim();
            if (draft.Length == 0) return;
            use!.IsEnabled = false;
            use.Content = "Checking...";
            var error = provider == ApiKeys.Provider.OpenAI ? await CloudTranscriber.Validate(draft) : await ClaudePolish.Validate(draft);
            use.Content = "Use key";
            use.IsEnabled = true;
            if (error is not null)
            {
                status.Text = error;
                status.Foreground = Ui.Bad;
                return;
            }
            if (!ApiKeys.Save(provider, draft))
            {
                status.Text = "Could not save the key to Credential Manager";
                status.Foreground = Ui.Bad;
                return;
            }
            field.Clear();
            if (provider == ApiKeys.Provider.OpenAI) _app.Settings.UseOpenAITranscription = true;
            else _app.Settings.UseClaudePunctuation = true;
            ShowPage(true);
        });
        buttons.Children.Add(use);
        if (ApiKeys.Has(provider))
        {
            var remove = Ui.Button("Remove", () =>
            {
                ApiKeys.Remove(provider);
                if (provider == ApiKeys.Provider.OpenAI) _app.Settings.UseOpenAITranscription = false;
                else _app.Settings.UseClaudePunctuation = false;
                ShowPage(true);
            });
            remove.Margin = new Thickness(4, 0, 0, 0);
            buttons.Children.Add(remove);
            status.Text = "A key is saved in Credential Manager.";
        }
        DockPanel.SetDock(buttons, Dock.Right);
        row.Children.Add(buttons);
        row.Children.Add(field);
        stack.Children.Add(row);
        stack.Children.Add(status);
        return stack;
    }

    FrameworkElement LearnedWords()
    {
        var learned = _app.Settings.LearnedWords;
        var panel = new StackPanel { Margin = new Thickness(0, 0, 0, 18) };
        panel.Children.Add(Ui.Title("Learned words"));
        var detail = Ui.Detail(learned.Count == 0
            ? "Fix a misheard word after dictating and talkflow learns it."
            : "Click a word to remove it.");
        detail.Margin = new Thickness(0, 4, 0, 8);
        panel.Children.Add(detail);
        var words = new WrapPanel();
        foreach (var word in learned)
        {
            var chip = Ui.Button(word + "  x", () =>
            {
                _app.Settings.LearnedWords = _app.Settings.LearnedWords.Where(w => w != word).ToList();
                ShowPage(true);
            });
            chip.Margin = new Thickness(0, 0, 6, 6);
            words.Children.Add(chip);
        }
        panel.Children.Add(words);
        return panel;
    }

    void ConfirmUninstall()
    {
        var message =
            "This removes talkflow, its speech engine and models, saved API keys, logs and the startup entry, then quits.\n\n" +
            $"Your stats and settings stay in {Paths.DataDir}, so installing talkflow again picks up where you left off. " +
            "Delete that folder for a completely fresh start.";
        if (MessageBox.Show(this, message, "Uninstall talkflow?", MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel) != MessageBoxResult.OK)
            return;
        _app.Uninstall();
    }
}
