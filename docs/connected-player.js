// Preserve the output's audible clock for transport and queue changes.
// Positions supplied by a controller are estimates unless it explicitly seeks.
export async function applyPlayerCommand(snapshot, engine) {
  if (engine.needsLoad) await engine.load(snapshot.position, snapshot.playing);
  else {
    if (snapshot.positionIntent !== 'preserve') await engine.seek(snapshot.position);
    if (snapshot.playing && !engine.playing()) await engine.play();
  }
  if (!snapshot.playing) await engine.pause();
}
