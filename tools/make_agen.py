"""Generate src/Agen.gs from agent/*.ps1 (each line as a JSON string)."""
import json, pathlib, sys

root = pathlib.Path(__file__).resolve().parent.parent
parts = [("AGENT_PS1", "agent.ps1", "Kode agen yang berjalan di tiap komputer lab"),
         ("INSTALL_PS1", "install.ps1", "Pemasang agen (dipanggil lewat ?f=install)"),
         ("UNINSTALL_PS1", "uninstall.ps1", "Penghapus agen (dipanggil lewat ?f=uninstall)")]

out = ["/**",
       " * Agen.gs - kode PowerShell agen ProktorLab.",
       " * Disimpan sebagai teks agar bisa diunduh oleh komputer lab.",
       " * Tidak perlu diubah.",
       " */"]
for var, fname, desc in parts:
    text = (root / "agent" / fname).read_text(encoding="utf-8").replace("\r\n", "\n").rstrip("\n")
    for i, ch in enumerate(text):
        if ord(ch) > 127:
            sys.exit(f"Non-ASCII char in {fname} at {i}: {ch!r}")
    if var == "AGENT_PS1":
        for ln in text.split("\n"):
            if ln.startswith("'@"):
                sys.exit("agent.ps1 must not have a line starting with '@")
    out.append("")
    out.append(f"// {desc}")
    out.append(f"var {var} = [")
    lines = text.split("\n")
    for i, ln in enumerate(lines):
        out.append("  " + json.dumps(ln) + ("," if i < len(lines) - 1 else ""))
    out.append("].join('\\n');")

(root / "apps-script" / "Agen.gs").write_text("\n".join(out) + "\n", encoding="utf-8")
print("Agen.gs written,", sum(1 for _ in (root / "apps-script" / "Agen.gs").open()), "lines")
