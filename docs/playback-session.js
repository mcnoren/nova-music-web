// A local resume point never carries playing intent or remote output ownership.
export function readPlaybackSession(raw) {
  try {
    const value = JSON.parse(raw);
    if (!value || !Array.isArray(value.queue) || !value.queue.length || value.queue.length > 10000 ||
        !Number.isInteger(value.index) || !value.queue[value.index] ||
        value.queue.some(song => !song || typeof song.id !== 'string' || !song.id || typeof song.title !== 'string') ||
        !Number.isFinite(value.position) || value.position < 0) return null;
    const duration = Number.isFinite(value.duration) && value.duration > 0 ? value.duration : value.queue[value.index].duration || 0;
    return {
      queue: value.queue, index: value.index,
      position: duration > 0 ? Math.min(value.position, duration) : value.position,
      duration, playing: false, shuffle: Boolean(value.shuffle), repeat: [0,1,2].includes(value.repeat) ? value.repeat : 0,
      context: typeof value.context === 'string' ? value.context : null,
      contextSongIDs: value.contextSongIDs && typeof value.contextSongIDs === 'object' && !Array.isArray(value.contextSongIDs) ? value.contextSongIDs : {},
      queueOrigins: Array.isArray(value.queueOrigins) && value.queueOrigins.length === value.queue.length ? value.queueOrigins : value.queue.map(() => value.context || null)
    };
  } catch { return null; }
}
