import WebKit

/// HD playback has its own filtering policy, independent of browser settings.
/// Remove ad instructions before the player consumes them; never block media
/// segment hosts or rewrite signed playback URLs.
@MainActor
enum HDYouTubeAdFilter {
    private static var compilation: Task<WKContentRuleList?, Never>?
    static func rules() async -> WKContentRuleList? {
        if let compilation { return await compilation.value }
        let task = Task<WKContentRuleList?, Never> {
            let cached: WKContentRuleList? = await withCheckedContinuation { continuation in
                WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: "NovaHDAds-v2") { list, _ in continuation.resume(returning: list) }
            }
            if let cached { return cached }
            do { return try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "NovaHDAds-v2", encodedContentRuleList: ruleJSON) }
            catch { print("HD content rules could not compile: \(error.localizedDescription)"); return nil }
        }
        compilation = task
        return await task.value
    }
    static let ruleJSON = #"""
    [
      {
        "trigger": {
          "url-filter": "^https?://([^/]+\\.)?doubleclick\\.net/"
        },
        "action": {
          "type": "block"
        }
      },
      {
        "trigger": {
          "url-filter": "^https?://([^/]+\\.)?googlesyndication\\.com/"
        },
        "action": {
          "type": "block"
        }
      },
      {
        "trigger": {
          "url-filter": "^https?://([^/]+\\.)?googleadservices\\.com/"
        },
        "action": {
          "type": "block"
        }
      },
      {
        "trigger": {
          "url-filter": "^https?://([^/]+\\.)?youtube\\.com/pagead/"
        },
        "action": {
          "type": "block"
        }
      },
      {
        "trigger": {
          "url-filter": "^https?://([^/]+\\.)?youtube\\.com/api/stats/ads"
        },
        "action": {
          "type": "block"
        }
      },
      {
        "trigger": {
          "url-filter": "^https?://([^/]+\\.)?youtube\\.com/get_midroll_info"
        },
        "action": {
          "type": "block"
        }
      }
    ]
    """#

    static let script = #"""
    (() => {
      const adKeys=['playerAds','adPlacements','adSlots','adBreakHeartbeatParams'];
      function clean(value) {
        if(!value || typeof value!=='object') return value;
        if(Array.isArray(value)) { value.forEach(clean); return value; }
        if(value.videoDetails || value.playabilityStatus || value.streamingData) {
          for(const key of adKeys) delete value[key];
        }
        for(const key of ['playerResponse','ytInitialPlayerResponse','raw_player_response']) {
          if(value[key] && typeof value[key]==='object') clean(value[key]);
        }
        return value;
      }
      const parse=JSON.parse;
      JSON.parse=function(...args) { return clean(Reflect.apply(parse,this,args)); };
      const responseJSON=Response.prototype.json;
      Response.prototype.json=function(...args) { return Reflect.apply(responseJSON,this,args).then(clean); };
      function watch(object,key,transform) {
        let value=transform(object[key]);
        try { Object.defineProperty(object,key,{configurable:true,enumerable:true,get:()=>value,set:v=>{value=transform(v)}}); } catch (_) {}
      }
      watch(window,'ytInitialPlayerResponse',clean);
      watch(window,'playerResponse',clean);
      watch(window,'ytplayer',value=>{
        if(value && typeof value==='object') watch(value,'config',config=>{
          if(config && typeof config==='object') watch(config,'args',args=>{
            if(args && typeof args==='object') {
              watch(args,'raw_player_response',clean);
              watch(args,'player_response',v=>{
                if(typeof v!=='string') return clean(v);
                try { return JSON.stringify(clean(parse(v))); } catch (_) {return v;}
              });
            }
            return args;
          });
          return config;
        });
        return value;
      });
    })();
    """#
}
