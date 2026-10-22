declare function require(name: string): any;
const fs = require("node:fs");
const answer: number = 19 + 23;
const message: string = `TypeScript: ${answer}\nПривет, LinuxFlashcard!\n`;
console.log(message.trimEnd());
fs.writeFileSync("result.txt", message, "utf8");
