"""Build the dashboard page: web/index.src.html -> web/index.html (adds the pinned library tags), then syntax-check the
inline scripts with Node when it is installed. Run from anywhere: python3 tools/build.py
Publishing is done by the sync workflow; this script only builds."""
import pathlib, re, shutil, subprocess, sys, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
web = root / 'web'
s = (web / 'index.src.html').read_text(encoding='utf-8')
s = s.replace('<!--SUPABASE-->', '<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js"></script>', 1)
s = s.replace('<!--XLSX-->', '<script src="https://cdn.sheetjs.com/xlsx-0.20.3/package/dist/xlsx.full.min.js"></script>', 1)
s = s.replace('<!--EXTRACT-->', '<script src="extract.js"></script>', 1)
assert '<!--SUPABASE-->' not in s and '<!--EXTRACT-->' not in s, 'placeholders missing in index.src.html'
(web / 'index.html').write_text(s, encoding='utf-8')
js = [m.group(1) for m in re.finditer(r'<script>([\s\S]*?)</script>', s)]
if shutil.which('node'):
    with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False, encoding='utf-8') as f:
        f.write('\n;\n'.join(js))
    r = subprocess.run(['node', '-e', "new Function(require('fs').readFileSync(process.argv[1],'utf8'))", f.name], capture_output=True, text=True)
    if r.returncode:
        print(r.stderr[:3000]); sys.exit('inline script syntax error')
    print('inline scripts parse OK')
else:
    print('node not installed: inline scripts not syntax-checked')
print('built web/index.html:', len(s), 'characters,', len(js), 'inline scripts')
