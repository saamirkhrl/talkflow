using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Talkflow;

/// <summary>
/// The look shared by talkflow's windows, after the Mac dashboard: paper and
/// ink, serif numerals, hairlines. Light or dark, following the Windows app mode.
/// </summary>
static class Ui
{
    public static readonly bool Dark = IsDarkMode();

    public static readonly Color PaperColor = Dark ? Color.FromRgb(0x1F, 0x1E, 0x22) : Color.FromRgb(0xF5, 0xF5, 0xF3);
    public static readonly Color InkColor = Dark ? Color.FromRgb(0xF5, 0xF5, 0xF3) : Color.FromRgb(0x1F, 0x1E, 0x22);

    public static readonly SolidColorBrush Paper = Freeze(new SolidColorBrush(PaperColor));
    public static readonly SolidColorBrush Ink = Freeze(new SolidColorBrush(InkColor));
    public static readonly SolidColorBrush Graphite = Freeze(new SolidColorBrush(Dark ? Color.FromRgb(0xA9, 0xA8, 0xAF) : Color.FromRgb(0x5F, 0x5E, 0x66)));
    public static readonly SolidColorBrush Line = Freeze(new SolidColorBrush(Color.FromArgb(0x1F, InkColor.R, InkColor.G, InkColor.B)));
    public static readonly SolidColorBrush Field = Freeze(new SolidColorBrush(Dark ? Color.FromRgb(0x2A, 0x29, 0x2E) : Colors.White));
    public static readonly SolidColorBrush Good = Freeze(new SolidColorBrush(Color.FromRgb(0x2F, 0x9E, 0x5B)));
    public static readonly SolidColorBrush Bad = Freeze(new SolidColorBrush(Color.FromRgb(0xD9, 0x48, 0x3B)));

    public static readonly FontFamily Sans = new("Segoe UI Variable Text, Segoe UI");

    /// <summary>
    /// A thin scroll bar for every window: a 6 px rounded thumb, no arrows,
    /// no track, faint until the pointer is on it. Registered once as the
    /// app's ScrollBar style (App.Main).
    /// </summary>
    public static Style ThinScrollBar()
    {
        string ink = $"{InkColor.R:X2}{InkColor.G:X2}{InkColor.B:X2}";
        string Thumb(string margin) => $@"
            <Thumb>
              <Thumb.Template>
                <ControlTemplate TargetType=""Thumb"">
                  <Border x:Name=""b"" CornerRadius=""3"" Background=""#33{ink}"" Margin=""{margin}""/>
                  <ControlTemplate.Triggers>
                    <Trigger Property=""IsMouseOver"" Value=""True""><Setter TargetName=""b"" Property=""Background"" Value=""#66{ink}""/></Trigger>
                    <Trigger Property=""IsDragging"" Value=""True""><Setter TargetName=""b"" Property=""Background"" Value=""#80{ink}""/></Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Thumb.Template>
            </Thumb>";
        string xaml = $@"
<Style TargetType=""ScrollBar"" xmlns=""http://schemas.microsoft.com/winfx/2006/xaml/presentation"" xmlns:x=""http://schemas.microsoft.com/winfx/2006/xaml"">
  <Setter Property=""Background"" Value=""Transparent""/>
  <Setter Property=""Width"" Value=""8""/>
  <Setter Property=""MinWidth"" Value=""8""/>
  <Setter Property=""Template"">
    <Setter.Value>
      <ControlTemplate TargetType=""ScrollBar"">
        <Track x:Name=""PART_Track"" IsDirectionReversed=""True"">
          <Track.Thumb>{Thumb("1,2,1,2")}</Track.Thumb>
        </Track>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
  <Style.Triggers>
    <Trigger Property=""Orientation"" Value=""Horizontal"">
      <Setter Property=""Width"" Value=""Auto""/>
      <Setter Property=""MinWidth"" Value=""0""/>
      <Setter Property=""Height"" Value=""8""/>
      <Setter Property=""MinHeight"" Value=""8""/>
      <Setter Property=""Template"">
        <Setter.Value>
          <ControlTemplate TargetType=""ScrollBar"">
            <Track x:Name=""PART_Track"">
              <Track.Thumb>{Thumb("2,1,2,1")}</Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Trigger>
  </Style.Triggers>
</Style>";
        return (Style)System.Windows.Markup.XamlReader.Parse(xaml);
    }
    public static readonly FontFamily Serif = new("Georgia");

    static SolidColorBrush Freeze(SolidColorBrush brush)
    {
        brush.Freeze();
        return brush;
    }

    static bool IsDarkMode()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int light && light == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }

    public static SolidColorBrush Ink_(double opacity) =>
        Freeze(new SolidColorBrush(Color.FromArgb((byte)Math.Round(opacity * 255), InkColor.R, InkColor.G, InkColor.B)));

    public static void Style(Window window, double width, double height)
    {
        window.Width = width;
        window.Height = height;
        window.Background = Paper;
        window.Foreground = Ink;
        window.FontFamily = Sans;
        window.FontSize = 13;
        window.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        window.ResizeMode = ResizeMode.CanMinimize;
        window.Icon = AppIcon;
        window.UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(window, TextFormattingMode.Display);
    }

    public static readonly BitmapImage AppIcon = LoadIcon();

    static BitmapImage LoadIcon()
    {
        var image = new BitmapImage();
        image.BeginInit();
        image.UriSource = new Uri("pack://application:,,,/talkflow;component/Assets/talkflow-256.png");
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.EndInit();
        image.Freeze();
        return image;
    }

    public static TextBlock Text(string text, double size = 13, Brush? color = null, FontWeight? weight = null, bool wrap = true) => new()
    {
        Text = text,
        FontSize = size,
        Foreground = color ?? Ink,
        FontWeight = weight ?? FontWeights.Normal,
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
    };

    public static TextBlock Title(string text) => Text(text, 14, Ink, FontWeights.SemiBold);

    public static TextBlock Detail(string text) => Text(text, 12, Graphite);

    public static TextBlock Numeral(string text, double size) => new()
    {
        Text = text,
        FontSize = size,
        FontFamily = Serif,
        Foreground = Ink,
    };

    public static Button Button(string label, Action onClick, bool primary = false)
    {
        var button = new Button
        {
            Content = label,
            Padding = new Thickness(14, 5, 14, 5),
            FontSize = 12,
            Cursor = Cursors.Hand,
            BorderThickness = new Thickness(1),
            Template = PillTemplate(),
        };
        SetPrimary(button, primary);
        button.Click += (_, _) => onClick();
        return button;
    }

    /// <summary>Filled ink (the one main action) or an outline.</summary>
    public static void SetPrimary(Button button, bool primary)
    {
        button.Foreground = primary ? Paper : Ink;
        button.Background = primary ? Ink : Brushes.Transparent;
        button.BorderBrush = primary ? Ink : Line;
    }

    /// <summary>A thin rounded progress bar: a hairline track with an ink fill.</summary>
    public static ProgressBar Progress()
    {
        var template = new ControlTemplate(typeof(ProgressBar));
        var root = new FrameworkElementFactory(typeof(Grid));
        var track = new FrameworkElementFactory(typeof(Border), "PART_Track");
        track.SetValue(Border.CornerRadiusProperty, new CornerRadius(2));
        track.SetValue(Border.BackgroundProperty, Line);
        var fill = new FrameworkElementFactory(typeof(Border), "PART_Indicator");
        fill.SetValue(Border.CornerRadiusProperty, new CornerRadius(2));
        fill.SetValue(Border.BackgroundProperty, Ink);
        fill.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Left);
        root.AppendChild(track);
        root.AppendChild(fill);
        template.VisualTree = root;
        return new ProgressBar { Height = 4, Minimum = 0, Maximum = 1, Template = template, IsTabStop = false };
    }

    /// <summary>A capsule button: border and fill from the button's own brushes.</summary>
    static ControlTemplate PillTemplate()
    {
        var template = new ControlTemplate(typeof(Button));
        var border = new FrameworkElementFactory(typeof(Border));
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(14));
        border.SetBinding(Border.BackgroundProperty, new System.Windows.Data.Binding("Background") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        border.SetBinding(Border.BorderBrushProperty, new System.Windows.Data.Binding("BorderBrush") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        border.SetBinding(Border.BorderThicknessProperty, new System.Windows.Data.Binding("BorderThickness") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        border.SetBinding(Border.PaddingProperty, new System.Windows.Data.Binding("Padding") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetValue(ContentPresenter.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        content.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(content);
        template.VisualTree = border;
        var disabled = new Trigger { Property = UIElement.IsEnabledProperty, Value = false };
        disabled.Setters.Add(new Setter(UIElement.OpacityProperty, 0.45));
        template.Triggers.Add(disabled);
        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(UIElement.OpacityProperty, 0.85));
        template.Triggers.Add(hover);
        return template;
    }

    /// <summary>A switch for a setting.</summary>
    public static CheckBox Switch(bool isOn, Action<bool> changed)
    {
        var box = new CheckBox { IsChecked = isOn, VerticalAlignment = VerticalAlignment.Top, Cursor = Cursors.Hand, Template = SwitchTemplate() };
        box.Checked += (_, _) => changed(true);
        box.Unchecked += (_, _) => changed(false);
        return box;
    }

    static ControlTemplate SwitchTemplate()
    {
        var template = new ControlTemplate(typeof(CheckBox));
        var track = new FrameworkElementFactory(typeof(Border), "track");
        track.SetValue(FrameworkElement.WidthProperty, 38.0);
        track.SetValue(FrameworkElement.HeightProperty, 22.0);
        track.SetValue(Border.CornerRadiusProperty, new CornerRadius(11));
        track.SetValue(Border.BackgroundProperty, Line);
        var knob = new FrameworkElementFactory(typeof(Border), "knob");
        knob.SetValue(FrameworkElement.WidthProperty, 16.0);
        knob.SetValue(FrameworkElement.HeightProperty, 16.0);
        knob.SetValue(Border.CornerRadiusProperty, new CornerRadius(8));
        knob.SetValue(Border.BackgroundProperty, Paper);
        knob.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Left);
        knob.SetValue(FrameworkElement.MarginProperty, new Thickness(3, 0, 3, 0));
        track.AppendChild(knob);
        template.VisualTree = track;
        var on = new Trigger { Property = ToggleButton.IsCheckedProperty, Value = true };
        on.Setters.Add(new Setter(Border.BackgroundProperty, Ink, "track"));
        on.Setters.Add(new Setter(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Right, "knob"));
        template.Triggers.Add(on);
        var disabled = new Trigger { Property = UIElement.IsEnabledProperty, Value = false };
        disabled.Setters.Add(new Setter(UIElement.OpacityProperty, 0.4));
        template.Triggers.Add(disabled);
        return template;
    }

    /// <summary>Title and detail on the left, a control on the right: one Settings row.</summary>
    public static FrameworkElement Row(string title, string detail, UIElement control, out TextBlock detailText)
    {
        var grid = new Grid { Margin = new Thickness(0, 0, 0, 18) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { Margin = new Thickness(0, 0, 16, 0) };
        left.Children.Add(Title(title));
        detailText = Detail(detail);
        detailText.Margin = new Thickness(0, 4, 0, 0);
        // A row whose title says it all has no detail line, not an empty one.
        if (detail.Length == 0) detailText.Visibility = Visibility.Collapsed;
        left.Children.Add(detailText);
        grid.Children.Add(left);
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        return grid;
    }

    public static FrameworkElement Row(string title, string detail, UIElement control) => Row(title, detail, control, out _);

    public static Border Card(UIElement child, Thickness? padding = null) => new()
    {
        BorderBrush = Line,
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(10),
        Padding = padding ?? new Thickness(12),
        Child = child,
    };

    public static TextBox TextField() => new()
    {
        Background = Field,
        Foreground = Ink,
        BorderBrush = Line,
        Padding = new Thickness(6, 4, 6, 4),
        FontSize = 12,
        CaretBrush = Ink,
    };

    public static PasswordBox SecretField() => new()
    {
        Background = Field,
        Foreground = Ink,
        BorderBrush = Line,
        Padding = new Thickness(6, 4, 6, 4),
        FontSize = 12,
        CaretBrush = Ink,
    };
}
