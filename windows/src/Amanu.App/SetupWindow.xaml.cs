using System.Windows;

namespace Amanu.App;

public partial class SetupWindow : Window
{
    private readonly AmanuRuntime runtime;

    public SetupWindow(AmanuRuntime runtime)
    {
        this.runtime = runtime;
        InitializeComponent();
        Form.LoadFrom(runtime);
    }

    private async void FinishButton_Click(object sender, RoutedEventArgs e)
    {
        FinishButton.IsEnabled = false;
        try
        {
            Form.Save();
            await runtime.CompleteSetupAsync();
            DialogResult = true;
            Close();
        }
        catch (Exception exception)
        {
            System.Windows.MessageBox.Show(exception.Message, "Настройка не завершена",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            FinishButton.IsEnabled = true;
        }
    }

    private void LaterButton_Click(object sender, RoutedEventArgs e) => Close();
}
