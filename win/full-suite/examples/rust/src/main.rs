fn main() -> std::io::Result<()> {
    let message = format!("Rust: {}\nПривет, LinuxFlashcard!\n", 19 + 23);
    print!("{message}");
    std::fs::write("result.txt", message)
}
