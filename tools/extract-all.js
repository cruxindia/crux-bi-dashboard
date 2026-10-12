// Extract every workbook in ../src/<kind>/ to ../out/<kind>/*.json using the same extractor as the browser.
// Usage: node extract-all.js <zonal|case|point>
const XLSX=require('xlsx'); global.XLSX=XLSX; const E=require('../web/extract.js'); const fs=require('fs'),path=require('path');
const kind=process.argv[2]; const src=path.join(__dirname,'..','src',kind), out=path.join(__dirname,'..','out',kind); fs.mkdirSync(out,{recursive:true});
for(const f of fs.readdirSync(src).filter(f=>/\.xlsx?$/i.test(f)).sort()){
  const wb=XLSX.readFile(path.join(src,f),{cellFormula:kind==='zonal',dense:kind!=='zonal',sheets:kind==='zonal'?['Main Tracker']:undefined});
  const x=E.extractWorkbook(wb,f); fs.writeFileSync(path.join(out,f.replace(/\.xlsx?$/i,'.json')),JSON.stringify(x));
  console.log(f,x.kind,(x.rows||[]).length,'rows',(x.issues||[]).length,'issues');
}
