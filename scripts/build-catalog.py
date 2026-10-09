"""Build a public, playable starting catalog from Nova's existing music source.

The website itself is static. No credentials or personal library are included.
Run manually to refresh the bundled snapshot; live search uses YouTube Data API.
"""
import concurrent.futures, datetime, json, re, pathlib, urllib.request, os

ROOT = pathlib.Path(__file__).resolve().parents[1]
NATIVE = pathlib.Path(os.environ.get('NOVA_NATIVE_SOURCE', ROOT.parent / 'NovaBrowser'))

def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values(): yield from walk(child)
    elif isinstance(value, list):
        for child in value: yield from walk(child)

def txt(value):
    if not isinstance(value, dict): return ''
    return value.get('simpleText', '') or ''.join(r.get('text','') for r in value.get('runs',[]))

def request(endpoint, body):
    body = dict(body, context={'client':{'clientName':'WEB_REMIX','clientVersion':'1.20240918.01.00','hl':'en','gl':'US'}})
    req = urllib.request.Request('https://music.youtube.com/youtubei/v1/'+endpoint+'?prettyPrint=false', data=json.dumps(body).encode(), headers={'Content-Type':'application/json','User-Agent':'Mozilla/5.0','Origin':'https://music.youtube.com'})
    with urllib.request.urlopen(req,timeout=25) as response: return json.load(response)

def tracks(root):
    result = {}
    for node in walk(root):
        item = node.get('musicResponsiveListItemRenderer') or node.get('musicTwoRowItemRenderer')
        if not item: continue
        cols = [txt(c.get('musicResponsiveListItemFlexColumnRenderer',{}).get('text')) for c in item.get('flexColumns',[])]
        title = cols[0] if cols else txt(item.get('title'))
        video = item.get('playlistItemData',{}).get('videoId')
        if not video:
            video = next((x['watchEndpoint']['videoId'] for x in walk(item) if 'videoId' in x.get('watchEndpoint',{})),None)
        if not video or not title: continue
        subtitle = cols[1] if len(cols)>1 else txt(item.get('subtitle'))
        parts = subtitle.split(' • ')
        artist = next((p for p in parts if p.strip() and p not in ['Song','Video'] and not re.match(r'^\d+:\d+',p)), '')
        runs = [x for x in walk(item.get('flexColumns',[])) if 'text' in x and 'navigationEndpoint' in x]
        album = next((x for x in runs if x.get('navigationEndpoint',{}).get('browseEndpoint',{}).get('browseId','').startswith('MPRE')), {})
        artist_id = next((x.get('navigationEndpoint',{}).get('browseEndpoint',{}).get('browseId') for x in runs if x.get('navigationEndpoint',{}).get('browseEndpoint',{}).get('browseId','').startswith('UC')),None)
        duration = next((txt(x['musicResponsiveListItemFixedColumnRenderer'].get('text')) for x in walk(item) if 'musicResponsiveListItemFixedColumnRenderer' in x), '')
        if not duration: duration = next((p for p in parts if re.match(r'^\d+:\d+',p)), '')
        thumb = next((x['thumbnails'][-1]['url'] for x in walk(item.get('thumbnail',{})) if x.get('thumbnails')), '')
        thumb = re.sub(r'=w\d+-h\d+', '=w544-h544', thumb)
        explicit = any(x.get('iconType') == 'MUSIC_EXPLICIT_BADGE' for x in walk(item))
        result[video]={'id':video,'title':title,'artist':artist,'artistId':artist_id,'album':album.get('text',''), 'albumId':album.get('navigationEndpoint',{}).get('browseEndpoint',{}).get('browseId'), 'artwork':thumb,'duration':sum(int(v)*60**i for i,v in enumerate(reversed(duration.split(':')))) if duration else 0,'explicit':explicit,'source':'youtube'}
    return list(result.values())

def albums(root):
    result={}
    for node in walk(root):
        item=node.get('musicTwoRowItemRenderer')
        if not item: continue
        browse=item.get('navigationEndpoint',{}).get('browseEndpoint',{})
        if not browse.get('browseId','').startswith('MPRE'):continue
        parts=txt(item.get('subtitle')).split(' • ')
        thumb=next((x['thumbnails'][-1]['url'] for x in walk(item.get('thumbnailRenderer') or item.get('thumbnail') or {}) if x.get('thumbnails')), '')
        artist=next((p for p in parts if p not in ['Album','Single','EP'] and not re.match(r'^\d{4}$',p)), '')
        year=next((p for p in parts if re.match(r'^\d{4}$',p)), '')
        result[browse['browseId']]={'id':browse['browseId'],'title':txt(item.get('title')),'artist':artist, 'year':year, 'type':parts[0] if parts else 'Album','artwork':re.sub(r'=w\d+-h\d+', '=w544-h544',thumb),'tracks':[],'complete':False}
    return list(result.values())

def composer_data():
    source=(NATIVE/'ClassicalMusicView.swift').read_text()
    names=re.findall(r'\.init\(name: "([^"]+)", years: "([^"]+)", era: "([^"]+)"\)',source)
    portraits=['bach','mozart','beethoven','chopin','tchaikovsky','debussy','vivaldi','rachmaninoff','handel','haydn','schubert','brahms','mendelssohn','liszt','dvorak','grieg','ravel','mahler','sibelius','price']
    composers=[{'id':p,'name':n,'years':y,'era':e,'artwork':'assets/composers/'+p+'.jpg'} for (n,y,e),p in zip(names,portraits)]
    library=(NATIVE/'ClassicalLibrary.swift').read_text()
    pattern=r'w\((\d+), "([^"]+)", "([^"]+)", \[([^\]]*)\], "([^"]+)",\s*"([^"]+)"'
    works=[]
    for idx,title,detail,tags,wiki,overview in re.findall(pattern,library):
        works.append({'id':str(len(works)), 'composerId':composers[int(idx)]['id'],'composer':names[int(idx)][0], 'title':title,'detail':detail,'tags':re.findall(r'\.(\w+)',tags)+['all','greatPieces'],'wiki':wiki,'overview':overview})
    for idx,title,detail,tags in re.findall(r'work\((\d+), "([^"\\]+)", "([^"\\]+)", \[([^\]]*)\]', library):
        if any(w['title']==title and w['composerId']==composers[int(idx)]['id'] for w in works):continue
        works.append({'id':str(len(works)),'composerId':composers[int(idx)]['id'],'composer':names[int(idx)][0],'title':title,'detail':detail,'tags':re.findall(r'\.(\w+)',tags)+['all','greatPieces']})
    for i,opus in enumerate(['21','36','55','60','67','68','92','93','125']):
        title='Symphony No. '+str(i+1)
        if not any(w['title']==title and w['composerId']=='beethoven' for w in works):
            works.append({'id':str(len(works)),'composerId':'beethoven','composer':names[2][0],'title':title,'detail':'Op. '+opus,'tags':['all','greatPieces','symphonies','orchestral']})
    return composers,works

def main():
    songs={}; releases={}; shelves={}
    jobs=[('Daft Punk','Electronic'),('Taylor Swift','Pop'),('Billie Eilish','Pop'),('The Weeknd','R&B'),('Kendrick Lamar','Hip-hop'),('SZA','R&B'),('Fleetwood Mac','Rock'),('Radiohead','Alternative'),('Lana Del Rey','Alternative'),('Bad Bunny','Latin'),('Beyoncé','Pop'),('Miles Davis','Jazz'),('Norah Jones','Jazz'),('focus piano music','Focus'),('chill relaxing music','Relax'),('workout music','Workout')]
    composers,works=composer_data()
    jobs += [(c['name'],'Classical') for c in composers]
    def fetch_job(job):
        query,genre=job
        try:
            root=request('search',{'query':query,'params':'EgWKAQIIAWoKEAkQChAFEAMQBA=='})
            found=tracks(root)[:20]
            for s in found:s['genre']=genre
            return query,found
        except Exception as exc:print('Catalog unavailable:',query,type(exc).__name__,flush=True);return query,[]
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        for query,found in pool.map(fetch_job,jobs):
            shelves[query]=[s['id'] for s in found]
            for s in found:songs.setdefault(s['id'],s)
    try:
        explore=request('browse',{'browseId':'FEmusic_explore'})
        for s in tracks(explore):songs.setdefault(s['id'],s)
        discovery=albums(explore)[:18]
        for a in discovery:releases[a['id']]=a
    except Exception as exc:print('Explore unavailable:',type(exc).__name__,flush=True);discovery=[]
    for query,_ in jobs[:12]:
        for sid in shelves[query]:
            s=songs[sid]
            if s.get('albumId'):
                releases.setdefault(s['albumId'],{'id':s['albumId'],'title':s['album'],'artist':s['artist'],'year':'','type':'Album','artwork':s['artwork'],'tracks':[],'complete':False})
    candidates=list(releases.values())[:35]
    def fetch_album(a):
        try:
            root=request('browse',{'browseId':a['id']})
            ss=tracks(root)
            tokens=[]
            for node in walk(root):
                shelf=node.get('musicPlaylistShelfRenderer') or node.get('musicShelfRenderer')
                if shelf:
                    tokens += [c['nextContinuationData']['continuation'] for c in shelf.get('continuations',[]) if 'nextContinuationData' in c]
            seen=set()
            while tokens:
                token=tokens.pop(0)
                if token in seen:raise ValueError('Repeated album continuation')
                seen.add(token);more=request('browse',{'continuation':token});ss+=tracks(more)
                for node in walk(more):
                    if 'nextContinuationData' in node:tokens.append(node['nextContinuationData']['continuation'])
            a['complete']=True
            for i,s in enumerate(ss):s.update(album=a['title'],albumId=a['id'],trackNumber=i+1,artist=s.get('artist') or a['artist'],artwork=s.get('artwork') or a['artwork'])
            return a,ss
        except Exception:return a,[]
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        for a,ss in pool.map(fetch_album,candidates):
            a['tracks']=[s['id'] for s in ss]
            for s in ss:songs[s['id']]=dict(songs.get(s['id'],{}),**s)
    for s in songs.values():
        if s.get('albumId') in releases:
            a=releases[s['albumId']]
            if s['id'] not in a['tracks'] and not a['complete']:a['tracks'].append(s['id'])
            if not s.get('artwork'):s['artwork']=a['artwork']
            if not s.get('artist'):s['artist']=a['artist']
        if not s.get('artist'):s['artist']='YouTube Music'
        if not s.get('artwork'):s['artwork']='https://i.ytimg.com/vi/'+s['id']+'/hqdefault.jpg'
    artists={}
    for s in songs.values():
        if s.get('artistId'): artists.setdefault(s['artistId'],{'id':s['artistId'],'name':s['artist'].split(',')[0].split(' & ')[0],'artwork':s['artwork']})
    output={'updated':datetime.datetime.now(datetime.timezone.utc).isoformat(),'songs':list(songs.values()),'albums':[a for a in releases.values() if a['tracks']],'artists':list(artists.values()),'shelves':shelves,'composers':composers,'works':works,'newReleases':[a['id'] for a in discovery]}
    (ROOT/'docs/catalog.json').write_text(json.dumps(output,ensure_ascii=False,separators=(',',':')))
    print('Catalog ready:',len(songs),'songs,',len(output['albums']),'albums,',len(works),'works',flush=True)

if __name__=='__main__':main()
