const cache = new Map();
const normalized = value => String(value || '').normalize('NFD').replace(/\p{M}/gu, '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
export function verifiedSongPage(pages, title, artist) {
  const name = normalized(title), performer = normalized(artist);
  if (!name || !performer) return null;
  return pages.find(page => {
    const intro = normalized(String(page.extract || '').slice(0, 900));
    let source; try { source = new URL(page.fullurl); } catch { return false; }
    return page.missing === undefined && !Object.hasOwn(page.pageprops || {}, 'disambiguation') &&
      source.protocol === 'https:' && source.hostname === 'en.wikipedia.org' &&
      normalized(String(page.title || '').replace(/\s*\([^)]*\)$/, '')) === name &&
      (` ${intro} `).includes(` ${performer} `) && /\b(song|single)\b/.test(intro) && String(page.extract || '').length > 80;
  }) || null;
}
export function songBackgroundText(extract) {
  const topics = /background|writing|composition|recording|production|release|reception|music video|performance|legacy|meaning|interpretation/i;
  const prose = String(extract || '').split('\n== ').filter(section => !section.includes('\\displaystyle') && !section.includes('\\begin{')).join('\n== ');
  let include = true, length = 0, contentEnd = 0; const lines = [];
  for (const raw of prose.split('\n')) {
    const line = raw.trim(), heading = line.match(/^(={2,6})\s*(.*?)\s*={2,6}$/);
    if (heading) {
      if (heading[1].length === 2) include = topics.test(heading[2]);
      if (include && length + heading[2].length < 9000) { lines.push('', heading[2], ''); length += heading[2].length + 3; }
    } else if (include && line) {
      if (length + line.length + 2 > 9000) break;
      lines.push(line, ''); length += line.length + 2; contentEnd = lines.length;
    }
  }
  return lines.slice(0, contentEnd).join('\n').trim();
}
export async function songBackground(title, artist, {fetcher = fetch, refresh = false} = {}) {
  const key = JSON.stringify([title, artist]);
  if (refresh) cache.delete(key);
  const old = cache.get(key);
  if (old && Date.now() - old.at < 3_600_000) return old.promise;
  const promise = (async () => {
    const request = async fields => {
      const query = new URLSearchParams({action:'query', format:'json', formatversion:'2', origin:'*', prop:'extracts|pageprops|info', inprop:'url', explaintext:'1', redirects:'1', ...fields});
      const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 12000);
      try {
        const response = await fetcher('https://en.wikipedia.org/w/api.php?' + query, {signal:controller.signal});
        if (!response.ok) throw Error('Song background unavailable');
        return (await response.json()).query?.pages || [];
      } finally { clearTimeout(timeout); }
    };
    let intro = null;
    try {
      intro = verifiedSongPage(await request({titles:[`${title} (${artist} song)`, `${title} (song)`, title].join('|'), exintro:'1'}), title, artist);
      if (!intro) intro = verifiedSongPage(await request({generator:'search', gsrsearch:`${title} ${artist} song`, gsrlimit:'5', exintro:'1'}), title, artist);
      if (!intro) return null;
      const full = verifiedSongPage(await request({titles:intro.title, exsectionformat:'wiki'}), title, artist);
      const page = full || intro;
      return {text:songBackgroundText(page.extract), source:page.fullurl, sourceName:'Wikipedia · CC BY-SA'};
    } catch { return intro ? {text:intro.extract, source:intro.fullurl, sourceName:'Wikipedia · CC BY-SA'} : null; }
  })();
  if (cache.size >= 200) cache.delete(cache.keys().next().value);
  cache.set(key, {at:Date.now(), promise});
  const result = await promise;
  if (!result) cache.delete(key);
  return result;
}
