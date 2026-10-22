import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

public class Hello {
    public static int add(int left, int right) {
        return left + right;
    }

    public static void main(String[] args) throws IOException {
        int answer = add(19, 23);
        String message = "Java: " + answer + "\nПривет, LinuxFlashcard!\n";
        System.out.print(message);
        Files.writeString(Path.of("result.txt"), message, StandardCharsets.UTF_8);
    }
}
