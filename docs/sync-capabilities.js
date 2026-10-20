// Library storage and native device playback are separate capabilities.
export function syncCapabilities({desktop=false, cloudConfigured=false, localPlayback=false}={}) {
 return {
  cloudConfigured,
  localPlayback:desktop&&localPlayback,
  localName:desktop?'This Mac':'This browser',
  libraryDescription:'Your library, playlists, profile and artwork sync privately through iCloud. Use the same Apple Account on your devices. Imported audio stays on its original device.',
  setupMessage:desktop
   ?'This Mac build needs iCloud signing before it can sync. Your library stays on this Mac.'
   :'Website iCloud sync is not configured yet. You can use iCloud sync in the Nova Music apps. Your library stays in this browser.',
  playbackDescription:desktop&&localPlayback
   ?'Playback controls, queues, handoff and lyrics connect directly over Wi-Fi between the Nova Music apps. Enable iCloud once on each device to connect them, allow Local Network access, and keep the apps open on the same network.'
   :'Direct Wi-Fi playback between devices is available in the Nova Music apps. This browser plays locally; iCloud library sync does not connect playback.',
 };
}
