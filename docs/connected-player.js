// Lyrics belong to the session's recording, independent of the audio output.
export function snapshotLyrics(snapshot) {
  const song = snapshot?.queue?.[snapshot.index];
  return song && snapshot.lyrics?.songID === song.id ? snapshot.lyrics : null;
}

// Preserve the output's audible clock for transport and queue changes.
// Positions supplied by a controller are estimates unless it explicitly seeks.
export async function applyPlayerCommand(snapshot, engine) {
  engine.lyrics?.(snapshotLyrics(snapshot));
  if (engine.needsLoad) await engine.load(snapshot.position, snapshot.playing);
  else {
    if (snapshot.positionIntent !== 'preserve') await engine.seek(snapshot.position);
    if (snapshot.playing && !engine.playing()) await engine.play();
  }
  if (!snapshot.playing) await engine.pause();
}
