#!/usr/bin/env python3
"""Build a universal, locally signed native Nova Music app. Requires Xcode."""
from pathlib import Path
import argparse, os, plistlib, shutil, subprocess, tempfile
from urllib.parse import urlparse
root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, default=root/'build'/'Nova Music.app')
parser.add_argument('--install', action='store_true')
parser.add_argument('--bundle-site', action='store_true', help='Embed the website and run it locally inside the app')
parser.add_argument('--display-name', help='Optional name shown in the app window and menu')
parser.add_argument('--preview-url', help='Local review website, for example http://127.0.0.1:4176/')
parser.add_argument('--cloud-profile', type=Path, help='Mac provisioning profile with the shared CloudKit container')
parser.add_argument('--cloud-environment', choices=['Development','Production'], help='Defaults to Development for previews and Production otherwise')
parser.add_argument('--signing-identity', help='Apple Development or Developer ID identity for the iCloud-enabled build')
args = parser.parse_args()
if bool(args.cloud_profile) != bool(args.signing_identity): parser.error('iCloud builds require both --cloud-profile and --signing-identity')
if args.bundle_site and args.preview_url: parser.error('Choose bundled interface or preview URL, not both')
if args.preview_url:
    preview = urlparse(args.preview_url)
    if preview.scheme != 'http' or preview.hostname != '127.0.0.1' or preview.path != '/' or preview.username or preview.password or preview.query or preview.fragment:
        parser.error('Preview URLs must be http://127.0.0.1:<port>/')
    if args.install: parser.error('Review builds cannot replace the installed app')
bundle_id = 'com.nova.music.mac.review' if args.preview_url else 'com.nova.music.mac'
app_name = args.display_name or ('Nova Music Review' if args.preview_url else 'Nova Music')
bundle_site = args.bundle_site or bool(args.cloud_profile and not args.preview_url)

app = args.output.resolve(); contents = app/'Contents'
(contents/'MacOS').mkdir(parents=True,exist_ok=True); (contents/'Resources').mkdir(exist_ok=True)
sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
with tempfile.TemporaryDirectory(prefix='nova-music-mac-') as temporary:
    binaries = []
    for arch in ['arm64','x86_64']:
        binary = Path(temporary)/arch; binaries.append(str(binary))
        subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-target',arch+'-apple-macos14.0','-sdk',sdk,str(root/'Sources'/'NovaMusicMac.swift'),str(root/'Sources'/'HDYouTubeAdFilter.swift'),str(root/'Sources'/'PlaybackActivity.swift'),str(root/'Sources'/'NativeMusicAudio.swift'),str(root/'Sources'/'NativeMusicCatalog.swift'),str(root/'Sources'/'NativeCloudStorage.swift'),str(root/'Sources'/'NativeLocalSite.swift'),str(root.parent.parent/'Shared'/'NovaMusicCore'/'MusicLocalPlayback.swift'),'-o',str(binary)],check=True)
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
if bundle_site:
    website = contents/'Resources'/'Website'
    if website.exists(): shutil.rmtree(website)
    shutil.copytree(root.parent/'docs',website,copy_function=shutil.copyfile)
with (contents/'Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleIdentifier':bundle_id,'CFBundleName':app_name,'CFBundleDisplayName':app_name,'CFBundleExecutable':'NovaMusic','CFBundleIconFile':'Music.icns','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0.5','CFBundleVersion':'6','LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'NSLocalNetworkUsageDescription':'Connect Nova Music on your iPhone and Mac over Wi-Fi for instant playback controls and synced lyrics.','NSBonjourServices':['_novamusic._tcp'],'NovaCloudEnabled':bool(args.cloud_profile),'NovaMusicBundledSite':bundle_site,'NSHumanReadableCopyright':'Nova Music',**({'NovaMusicPreviewURL':args.preview_url} if args.preview_url else {})},f)
subprocess.run(['xattr','-cr',str(app)],check=True)
if args.cloud_profile:
    shutil.copyfile(args.cloud_profile, contents/'embedded.provisionprofile')
    subprocess.run(['xattr','-cr',str(app)],check=True)
    with tempfile.NamedTemporaryFile(suffix='.plist') as entitlements:
        profile = plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(args.cloud_profile)]))
        granted = profile.get('Entitlements',{})
        if granted.get('com.apple.developer.icloud-services') != '*' and 'CloudKit' not in granted.get('com.apple.developer.icloud-services',[]) or 'iCloud.com.example.NovaMusic' not in granted.get('com.apple.developer.icloud-container-identifiers',[]):
            raise SystemExit('The profile must grant iCloud.com.example.NovaMusic')
        identifier = granted.get('com.apple.application-identifier', granted.get('application-identifier',''))
        if not identifier.endswith('.'+bundle_id): raise SystemExit('The Mac profile must match '+bundle_id)
        environment = args.cloud_environment or ('Development' if args.preview_url else 'Production')
        allowed_environments = granted.get('com.apple.developer.icloud-container-environment',[])
        if allowed_environments != '*' and environment not in allowed_environments:
            raise SystemExit('The Mac profile does not grant the '+environment+' iCloud environment')
        requested = {
            'com.apple.security.app-sandbox':True,
            'com.apple.security.network.client':True,
            'com.apple.security.files.user-selected.read-write':True,
            'com.apple.application-identifier':identifier,
            'com.apple.developer.icloud-container-identifiers':['iCloud.com.example.NovaMusic'],
            'com.apple.developer.icloud-services':['CloudKit'],
            'com.apple.developer.icloud-container-environment':environment,
        }
        requested['com.apple.security.network.server'] = True
        if environment == 'Development':
            development_containers = granted.get('com.apple.developer.icloud-container-development-container-identifiers',[])
            if 'iCloud.com.example.NovaMusic' in development_containers:
                requested['com.apple.developer.icloud-container-development-container-identifiers'] = ['iCloud.com.example.NovaMusic']
        if granted.get('com.apple.developer.team-identifier'):
            requested['com.apple.developer.team-identifier'] = granted['com.apple.developer.team-identifier']
        # Profile grants may be wildcards/lists. Sign only the concrete capabilities used by this app.
        plistlib.dump(requested,entitlements);entitlements.flush()
        subprocess.run(['codesign','--force','--sign',args.signing_identity,'--entitlements',entitlements.name,'--identifier',bundle_id,str(app)],check=True)
else:
    subprocess.run(['codesign','--force','--sign','-','--identifier',bundle_id,str(app)],check=True)
if args.install:
    installed = Path.home()/'Applications'/'Nova Music.app'; installed.parent.mkdir(exist_ok=True)
    if installed.exists():
        with (installed/'Contents'/'Info.plist').open('rb') as f: existing = plistlib.load(f)
        if existing.get('CFBundleIdentifier')!='com.nova.music.mac': raise SystemExit('A different Nova Music app already exists; built app remains at '+str(app))
        shutil.rmtree(installed)
    shutil.copytree(app,installed); print('Installed:',installed)
print('Built:',app)
