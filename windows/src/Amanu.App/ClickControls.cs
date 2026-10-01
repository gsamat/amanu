using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using CheckBox = System.Windows.Controls.CheckBox;
using RadioButton = System.Windows.Controls.RadioButton;

namespace Amanu.App;

/// <summary>
/// A check box that UI Automation toggles by clicking it. Every switch in Amanu
/// saves its setting in Click, and WPF's own peer flips IsChecked without raising
/// Click — so Narrator or Voice Access would move the switch and save nothing,
/// leaving it showing a setting that isn't in config.json.
/// </summary>
internal sealed class ClickCheckBox : CheckBox
{
    // Derived controls do not receive Fluent's implicit CheckBox foreground style.
    // Keep labels in the native theme palette, including changes while the window is open.
    public ClickCheckBox() => SetResourceReference(ForegroundProperty, Ui.Primary);

    protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);

    private void ClickFromAutomation() => OnClick();

    private sealed class Peer(ClickCheckBox owner) : CheckBoxAutomationPeer(owner), IToggleProvider
    {
        ToggleState IToggleProvider.ToggleState => owner.IsChecked switch
        {
            true => ToggleState.On,
            false => ToggleState.Off,
            null => ToggleState.Indeterminate,
        };

        void IToggleProvider.Toggle()
        {
            if (!IsEnabled()) throw new ElementNotEnabledException();
            owner.ClickFromAutomation();
        }
    }
}

/// <summary>
/// A choice card that UI Automation selects by clicking it, for the reason
/// <see cref="ClickCheckBox"/> gives: the cards save in Click too.
/// </summary>
internal sealed class ClickRadioButton : RadioButton
{
    protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);

    private void ClickFromAutomation() => OnClick();

    private sealed class Peer(ClickRadioButton owner) : RadioButtonAutomationPeer(owner), ISelectionItemProvider
    {
        bool ISelectionItemProvider.IsSelected => owner.IsChecked == true;

        IRawElementProviderSimple? ISelectionItemProvider.SelectionContainer => null;

        void ISelectionItemProvider.Select()
        {
            if (!IsEnabled()) throw new ElementNotEnabledException();
            if (owner.IsChecked != true) owner.ClickFromAutomation();
        }

        // What WPF's own peer does: a radio button can be added to a selection
        // only by being the selection, and taken out of it only by another.
        void ISelectionItemProvider.AddToSelection()
        {
            if (owner.IsChecked != true) throw new InvalidOperationException();
        }

        void ISelectionItemProvider.RemoveFromSelection()
        {
            if (owner.IsChecked == true) throw new InvalidOperationException();
        }
    }
}
