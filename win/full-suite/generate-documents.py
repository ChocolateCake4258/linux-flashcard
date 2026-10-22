#!/usr/bin/python3
"""Create small editable office/math examples without downloading templates."""
import argparse
from pathlib import Path
import zipfile

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('output',type=Path)
args=parser.parse_args()
args.output.mkdir(parents=True,exist_ok=True)

def odf(name,mimetype,content):
    target=args.output/name
    if target.exists():raise SystemExit('Refusing existing example: '+str(target))
    with zipfile.ZipFile(target,'w') as archive:
        archive.writestr('mimetype',mimetype,compress_type=zipfile.ZIP_STORED)
        archive.writestr('content.xml',content)
        archive.writestr('META-INF/manifest.xml',f'''<?xml version="1.0" encoding="UTF-8"?>
<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
<manifest:file-entry manifest:full-path="/" manifest:media-type="{mimetype}"/>
<manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
</manifest:manifest>''')

prefix='''<?xml version="1.0" encoding="UTF-8"?>
<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
 xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
 xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" office:version="1.2">'''
odf('lesson.odt','application/vnd.oasis.opendocument.text',prefix+'''
<office:body><office:text><text:p>LinuxFlashcard: 42</text:p>
<text:p>Привет, LinuxFlashcard!</text:p></office:text></office:body></office:document-content>''')
odf('lesson.ods','application/vnd.oasis.opendocument.spreadsheet',prefix+'''
<office:body><office:spreadsheet><table:table table:name="Lesson"><table:table-row>
<table:table-cell office:value-type="float" office:value="19"><text:p>19</text:p></table:table-cell>
<table:table-cell office:value-type="float" office:value="23"><text:p>23</text:p></table:table-cell>
<table:table-cell office:value-type="float" office:value="42"><text:p>42</text:p></table:table-cell>
</table:table-row></table:table></office:spreadsheet></office:body></office:document-content>''')
target=args.output/'lesson.ggb'
if target.exists():raise SystemExit('Refusing existing math example.')
with zipfile.ZipFile(target,'w') as archive:
    archive.writestr('geogebra.xml','''<?xml version="1.0" encoding="utf-8"?>
<geogebra format="4.0"><euclidianView><size width="800" height="600"/>
<coordSystem xZero="400" yZero="300" scale="50" yscale="50"/>
<evSettings axes="true" grid="true"/></euclidianView><construction title="LinuxFlashcard">
<element type="point" label="A"><show object="true" label="true"/>
<objColor r="0" g="0" b="255" alpha="0"/><coords x="1" y="2" z="1"/>
<pointSize val="5"/><pointStyle val="0"/></element>
</construction></geogebra>''')
print('Created editable ODT, ODS and GeoGebra examples in',args.output)
