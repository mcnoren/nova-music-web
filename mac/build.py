#!/usr/bin/env python3
"""Build a universal, locally signed native Nova Music app. Requires Xcode."""
from pathlib import Path
import argparse, os, plistlib, shutil, subprocess, tempfile
root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, default=root/'build'/'Nova Music.app')
parser.add_argument('--install', action='store_true')
args = parser.parse_args()
app = args.output.resolve(); contents = app/'Contents'
(contents/'MacOS').mkdir(parents=True,exist_ok=True); (contents/'Resources').mkdir(exist_ok=True)
sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
with tempfile.TemporaryDirectory(prefix='nova-music-mac-') as temporary:
    binaries = []
    for arch in ['arm64','x86_64']:
        binary = Path(temporary)/arch; binaries.append(str(binary))
        subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-target',arch+'-apple-macos14.0','-sdk',sdk,str(root/'Sources'/'NovaMusicMac.swift'),str(root/'Sources'/'HDYouTubeAdFilter.swift'),str(root/'Sources'/'PlaybackActivity.swift'),'-o',str(binary)],check=True)
    subprocess.run(['xcrun','lipo','-create',*binaries,'-output',str(contents/'MacOS'/'NovaMusic')],check=True)
shutil.copyfile(root.parent/'docs'/'assets'/'icon-512.png',contents/'Resources'/'icon-512.png')
with tempfile.TemporaryDirectory(prefix='nova-music-icon-') as temporary:
    icons = Path(temporary)/'Music.iconset'; icons.mkdir()
    source = contents/'Resources'/'icon-512.png'
    for size in [16,32,128,256,512]:
        subprocess.run(['sips','-z',str(size),str(size),str(source),'--out',str(icons/('icon_'+str(size)+'x'+str(size)+'.png'))],check=True,stdout=subprocess.DEVNULL)
        if size <= 256:
            subprocess.run(['sips','-z',str(size*2),str(size*2),str(source),'--out',str(icons/('icon_'+str(size)+'x'+str(size)+'@2x.png'))],check=True,stdout=subprocess.DEVNULL)
    subprocess.run(['iconutil','-c','icns',str(icons),'-o',str(contents/'Resources'/'Music.icns')],check=True)
with (contents/'Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleIdentifier':'com.nova.music.mac','CFBundleName':'Nova Music','CFBundleDisplayName':'Nova Music','CFBundleExecutable':'NovaMusic','CFBundleIconFile':'Music.icns','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0.1','CFBundleVersion':'2','LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'NSHumanReadableCopyright':'Nova Music'},f)
subprocess.run(['xattr','-cr',str(app)],check=True)
subprocess.run(['codesign','--force','--sign','-','--identifier','com.nova.music.mac',str(app)],check=True)
if args.install:
    installed = Path.home()/'Applications'/'Nova Music.app'; installed.parent.mkdir(exist_ok=True)
    if installed.exists():
        with (installed/'Contents'/'Info.plist').open('rb') as f: existing = plistlib.load(f)
        if existing.get('CFBundleIdentifier')!='com.nova.music.mac': raise SystemExit('A different Nova Music app already exists; built app remains at '+str(app))
        shutil.rmtree(installed)
    shutil.copytree(app,installed); print('Installed:',installed)
print('Built:',app)
