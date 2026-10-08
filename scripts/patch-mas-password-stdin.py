"""Pinned MAS 1.26.0 CLI: accept setup password on stdin, never process arguments."""
from pathlib import Path
import sys
p = Path(sys.argv[1]) / 'crates/cli/src/commands/manage.rs'
s = p.read_text()
if 'password_stdin: bool' in s:
    raise SystemExit(0)
a = '        password: Option<String>,\n'
b = a + '\n        /// Read the registration password from stdin (Indexa local build).\n        #[arg(long, conflicts_with = "password")]\n        password_stdin: bool,\n'
assert s.count(a) == 1
s = s.replace(a, b)
a = '            SC::RegisterUser {\n                username,\n                password,\n'
assert s.count(a) == 1
s = s.replace(a, a + '                password_stdin,\n')
a = '                ignore_password_complexity,\n            } => {\n                let http_client = mas_http::reqwest_client();\n'
b = '''                ignore_password_complexity,
            } => {
                let password = if password_stdin {
                    use std::io::Read;
                    let mut input = String::new();
                    std::io::stdin().take(4097).read_to_string(&mut input)?;
                    anyhow::ensure!((16..=4096).contains(&input.len()), "Invalid password length");
                    Some(input)
                } else { password };
''' + '                let http_client = mas_http::reqwest_client();\n'
assert s.count(a) == 1
s = s.replace(a, b)
p.write_text(s)
