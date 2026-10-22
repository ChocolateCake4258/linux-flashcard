using System.Text;

Console.OutputEncoding = new UTF8Encoding(false);
int answer = 19 + 23;
string message = $"C#: {answer}\nПривет, LinuxFlashcard!\n";
Console.Write(message);
File.WriteAllText("result.txt", message, new UTF8Encoding(false));
