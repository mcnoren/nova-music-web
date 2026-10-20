"""Refresh ES module and offline-shell versions after website changes."""
from pathlib import Path
import hashlib
import re
root = Path(__file__).resolve().parents[1] / 'docs'
def digest(name): return hashlib.sha256((root / name).read_bytes()).hexdigest()[:12]
for filename in ['search-suggestions.js','search-ranking.js','search-suggestions.js','music-catalog.js','native-catalog.js','music-search.js','collection-position.js','artist-library.js','collection-artwork.js','sync-capabilities.js','sync-model.js','sync-client.js','github-sync-client.js','icloud-sync-client.js','playlist-import.js','connected-player.js','playback-health.js','native-player.js','connect.js','playback-session.js','lyric-presentation.js','app.js']:
    path = root / filename
    content = path.read_text()
    content = re.sub(r"(from ['\"]\./)((?:collection-position|collection-artwork|artist-library|playback-session|lyric-presentation|(?:sync-(?:model|client|config|capabilities)|github-sync-client|icloud-sync-client)|music-search|search-suggestions|search-ranking|music-catalog|native-catalog|profile|lyrics|playlist-import|connected-player|playback-health|native-player|connect)\.js)(?:\?v=[a-f0-9]+)?(['\"])", lambda m: m[1] + m[2] + '?v=' + digest(m[2]) + m[3], content)
    path.write_text(content)
index = root / 'index.html'
index.write_text(re.sub(r'(styles\.css|app\.js)(?:\?v=[a-f0-9]+)?', lambda m: m[1] + '?v=' + digest(m[1]), index.read_text()))
assets = ['./','index.html'] + [name + '?v=' + digest(name) for name in ['styles.css','app.js','collection-position.js','artist-library.js','collection-artwork.js','sync-capabilities.js','sync-model.js','sync-client.js','github-sync-client.js','icloud-sync-client.js','sync-config.js','music-search.js','search-ranking.js','search-suggestions.js','music-catalog.js','native-catalog.js','profile.js','lyrics.js','playlist-import.js','connected-player.js','playback-health.js','native-player.js','connect.js','playback-session.js','lyric-presentation.js']] + ['catalog.json','manifest.webmanifest','assets/icon-192.png']
sw = root / 'sw.js'
content = sw.read_text()
content = re.sub(r"const CACHE='[^']+';", "const CACHE='nova-music-shell-" + digest('app.js') + "';", content)
content = re.sub(r'cache\.addAll\(\[.*?\]\)', 'cache.addAll(' + repr(assets) + ')', content)
sw.write_text(content)
