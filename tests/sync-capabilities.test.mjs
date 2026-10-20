import test from 'node:test';
import assert from 'node:assert/strict';
import {syncCapabilities} from '../docs/sync-capabilities.js';

test('browser cloud configuration does not imply native Wi-Fi access',()=>{
 const value=syncCapabilities({cloudConfigured:true,localPlayback:true});
 assert.equal(value.cloudConfigured,true);
 assert.equal(value.localPlayback,false);
 assert.equal(value.localName,'This browser');
 assert.match(value.playbackDescription,/browser plays locally/);
});
test('unconfigured website explains local storage without offering a working cloud connection',()=>{
 const value=syncCapabilities();
 assert.equal(value.cloudConfigured,false);
 assert.match(value.setupMessage,/not configured/);
 assert.match(value.setupMessage,/library stays in this browser/);
});
test('native Mac separates iCloud library from direct Wi-Fi playback',()=>{
 const value=syncCapabilities({desktop:true,cloudConfigured:true,localPlayback:true});
 assert.equal(value.localPlayback,true);
 assert.equal(value.localName,'This Mac');
 assert.match(value.libraryDescription,/privately through iCloud/);
 assert.match(value.playbackDescription,/directly over Wi-Fi/);
 assert.match(value.playbackDescription,/Local Network/);
});
