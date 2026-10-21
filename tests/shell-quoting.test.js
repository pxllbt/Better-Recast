// A directory name is not a command.
//
// The output directory is whatever the user picks with the folder browser, and
// a directory name can contain a dollar sign, a backtick, a semicolon or a
// command substitution. The service interpolated that path into a shell
// script string. Inside DOUBLE QUOTES `$(...)` and backticks are still
// expanded by the shell, so a directory named
//
//     $(touch /tmp/pwned)
//
// ran its own command as the desktop user the moment a recording started.
//
// The fix is to quote every value that reaches a shell, and to quote it so
// that nothing in it is expanded. Single quotes make everything literal; the
// only character that cannot appear inside a single-quoted string is a single
// quote itself, which is escaped by ending the quote, adding an escaped quote
// and reopening it.
//
// This file pins the rule AND the escaping, because a quoting helper that
// forgets the single-quote case is worse than none: it looks careful.
const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const SRC = fs.readFileSync(path.join(ROOT, "Service.qml"), "utf8");

let failed = 0;
const ok = (name, cond) => {
    if (cond) {
        console.log(`PASS ${name}`);
    } else {
        failed++;
        console.log(`FAIL ${name}`);
    }
};

// --- the helper exists and behaves ---------------------------------------
ok("Service.qml defines shellQuote", /function\s+shellQuote\s*\(/.test(SRC));

// Extract the helper and run it, so the escaping is checked and not just
// described.
const m = SRC.match(/function\s+shellQuote\s*\([^)]*\)\s*\{[\s\S]*?\n {4}\}/);
ok("shellQuote is extractable", !!m);

let q = null;
if (m) {
    const fn = new Function(`return (${m[0].replace(/^function/, "function")})`)();
    q = (v) => fn(v);

    ok("a plain path is quoted", q("/home/u/Videos") === "'/home/u/Videos'");

    const evil = "/tmp/$(touch /tmp/pwned)";
    const quoted = q(evil);
    ok("command substitution is inside single quotes",
        quoted.startsWith("'") && quoted.endsWith("'") && quoted.includes("$(touch"));
    // The whole point: nothing inside the quotes is expandable.
    ok("the quoted value contains no unescaped single quote",
        !/[^\\]'/.test(quoted.slice(1, -1)));

    const withQuote = "/tmp/it's";
    const q2 = q(withQuote);
    ok("a single quote in the value is escaped", q2 === "'/tmp/it'\\''s'");

    ok("a backtick is inert inside the quotes", q("`id`").includes("`id`"));
    ok("a semicolon is inert inside the quotes", q("/tmp/a; rm -rf ~").includes("; rm -rf ~"));
}

// --- no value reaches a shell unquoted ------------------------------------
const USER_VALUES = ["outputDir", "fileDir", "recordingFile", "node", "lastTarget"];
const shellLines = SRC.split("\n").filter((l) => /"bash",\s*"-c"/.test(l));
const raw = [];
for (const line of shellLines) {
    for (const v of USER_VALUES) {
        // `+ VAR +` inside a shell string, with no shellQuote() around it.
        const re = new RegExp(`"\\s*\\+\\s*${v}\\s*\\+`);
        if (re.test(line) && !line.includes("shellQuote(")) {
            raw.push(`${v}: ${line.trim().slice(0, 90)}`);
        }
    }
}
ok("no user-controlled value is interpolated into a shell string unquoted",
    raw.length === 0);
if (raw.length) console.log("  " + raw.join("\n  "));

// --- and the shell really treats a quoted path as data -------------------
// The proof that the quoting works, not just that it is present: hand the
// same string to a real shell and see that nothing ran.
const { execFileSync } = require("child_process");
const marker = "/tmp/better-recast-quoting-probe";
try { fs.unlinkSync(marker); } catch {}
const payload = `/tmp/$(touch ${marker})`;
const script = `printf '%s' ${q(payload)} > /dev/null; test -e ${marker} && echo EXECUTED || echo SAFE`;
const verdict = execFileSync("bash", ["-c", script], { encoding: "utf8" }).trim();
ok("a hostile directory name is not executed by the shell", verdict === "SAFE");
try { fs.unlinkSync(marker); } catch {}

if (failed) {
    console.log(`\n${failed} failing`);
    process.exit(1);
}
console.log("\nall green");
