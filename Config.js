.pragma library

// pix.recast config defaults, normalization, and encoder profile rules.
// Singleton import: used by Service.qml at startup and Panel.qml for defaults.

function defaultConfig() {
  return {
    // Recording target
    targetMode: "auto",       // "auto" | "monitor" | "region" | "portal"
    monitorName: "",           // explicit monitor (from --list-monitors)
    region: "",                // "WxH+X+Y" or ""

    // Video
    codec: "auto",            // "auto" | "h264" | "hevc" | "av1" | "vp9" | "vp8"
    encoder: "gpu",           // "gpu" | "cpu"
    bitrateMode: "auto",      // "auto" | "qp" | "vbr" | "cbr"
    quality: "auto",          // "auto" | "medium" | "high" | "very_high" | "ultra" | number (kbps for cbr)
    fps: 60,
    resolution: "",           // "" = native, "1920x1080", etc.
    frameMode: "cfr",         // "cfr" | "vfr" | "content"
    colorRange: "limited",    // "limited" | "full"
    tune: "performance",      // "performance" | "quality"
    keyInterval: 2.0,
    cursor: true,

    // Audio
    audioEnabled: true,
    audioDesktop: true,
    audioMicrophone: false,
    audioCodec: "aac",        // "aac" | "opus"
    audioBitrate: 0,          // 0 = auto

    // Container
    container: "mp4",         // "mp4" | "mkv" | "webm"

    // Output
    outputDir: "",            // "" = auto from XDG_VIDEOS_DIR

    // Webcam overlay
    webcamEnabled: false,
    webcamDevice: "",
    webcamSize: "medium",     // "small" | "medium" | "large"

    // Streaming (reuses the recording encode pipeline with stream overrides)
    mode: "record",           // "record" | "stream"
    streamUrl: "",            // RTMP server URL (e.g. rtmp://push.tiktokcdn.com/live/)
    streamKey: "",            // per-session stream key (not persisted unless streamRemember)
    streamKbps: 6000,         // CBR video bitrate
    streamPlatform: "custom", // "custom" | "tiktok" | "twitch" | "youtube"
    streamRemember: false,    // persist URL/key to shell.json when true
    streamBackupLocal: false, // also save a local `-ro` copy while streaming

    // UI
    advanced: false,
    showTimer: true,

    // State (non-user, runtime)
    _lastMonitor: "",
    _lastRegion: ""
  }
}

function applyGpuProfile(config, gpuInfo) {
  return resolveProfile(config, gpuInfo)
}

function resolveProfile(config, gpuInfo) {
  // Resolve "auto"/"" sentinels against detected hardware. Never mutates
  // the persisted config.
  var resolved = Object.assign({}, config)
  var vendor = (gpuInfo && gpuInfo.vendor) || "unknown"
  var codecs = (gpuInfo && gpuInfo.codecs) || []

  if (resolved.codec === "auto" || resolved.codec === "") {
    if (vendor === "nvidia") resolved.codec = codecs.indexOf("hevc") !== -1 ? "hevc" : "h264"
    else if (vendor === "amd" || vendor === "intel") {
      if (codecs.indexOf("av1") !== -1) resolved.codec = "av1"
      else if (codecs.indexOf("hevc") !== -1) resolved.codec = "hevc"
      else resolved.codec = "h264"
    } else resolved.codec = "h264"
  }
  if (resolved.bitrateMode === "auto" || resolved.bitrateMode === "") {
    resolved.bitrateMode = vendor === "unknown" ? "qp" : "vbr"
  }
  if (resolved.quality === "auto" || resolved.quality === "") {
    resolved.quality = vendor === "intel" ? "high"
      : (vendor === "unknown" ? "medium" : "very_high")
  }
  if (resolved.encoder === "auto" || resolved.encoder === "") {
    resolved.encoder = vendor === "unknown" ? "cpu" : "gpu"
  }
  if (resolved.tune === "auto" || resolved.tune === "") {
    resolved.tune = "performance"
  }
  return resolved
}

function streamPlatformDefaults(platform) {
  // Auto-suggested encode settings per platform. The panel applies these when
  // the user picks a platform and hasn't overridden the value yet.
  var map = {
    tiktok:  { kbps: 6000,  resolution: "1080x1920", fps: 60, label: "TikTok Live" },
    twitch:  { kbps: 6000,  resolution: "1920x1080", fps: 60, label: "Twitch" },
    youtube: { kbps: 12000, resolution: "1920x1080", fps: 60, label: "YouTube" },
    custom:  { kbps: 6000,  resolution: "",          fps: 60, label: "Custom / Other" }
  }
  return map[platform] || map.custom
}

function streamOutput(config) {
  // Concatenate server URL + stream key into a single gsr `-o` target.
  // gsr accepts "rtmp://host/app/key" or, when the URL ends in a key slot,
  // "rtmp://host/app/streamKey".
  var url = String(config.streamUrl || "").trim()
  var key = String(config.streamKey || "").trim()
  if (url.charAt(url.length - 1) !== "/" && url.length > 0 && key.length > 0) url += "/"
  return url + key
}

function encodeGsrArgs(config, gpuInfo, target, streamMode) {
  var args = []
  config = resolveProfile(config, gpuInfo)
  streamMode = streamMode === true

  // Target
  if (target.type === "monitor" && target.name) {
    args.push("-w", target.name)
  } else if (target.type === "region" && target.geometry) {
    args.push("-w", "region", "-region", target.geometry)
  } else {
    args.push("-w", "portal")
  }

  // Codec: streams are H.264 (tune instant-feedback) regardless of the
  // recording codec preference; recordings keep the hardware-resolved codec.
  var codec = streamMode ? "h264" : config.codec
  if (codec === "auto") codec = "h264"
  args.push("-k", codec)

  // Bitrate mode: CBR for streaming, resolved mode for recordings.
  var bm = streamMode ? "cbr" : config.bitrateMode
  if (bm === "auto") bm = streamMode ? "cbr" : "qp"
  args.push("-bm", bm)

  // Quality: CBR kbps for streams, resolved preset for recordings.
  var q = streamMode ? config.streamKbps : config.quality
  if (q === "auto" || q === "" || q === undefined || q === null) {
    q = streamMode ? 6000 : "very_high"
  }
  args.push("-q", String(q))

  // Frame rate
  args.push("-f", String(config.fps || 60))

  // Frame rate mode: constant for streams; recordings follow the setting.
  args.push("-fm", streamMode ? "cfr" : (config.frameMode || "cfr"))

  // Resolution
  if (config.resolution && config.resolution !== "") {
    args.push("-s", config.resolution)
  } else {
    args.push("-s", "0x0")
  }

  // Encoder
  args.push("-encoder", config.encoder || "gpu")
  args.push("-fallback-cpu-encoding", "yes")

  // Color range
  args.push("-cr", config.colorRange || "limited")

  // Tune (NVIDIA only, no-op otherwise)
  if (streamMode) {
    args.push("-tune", "instant-feedback")
  } else if (config.tune) {
    args.push("-tune", config.tune)
  }

  // Keyframe interval
  args.push("-keyint", String(config.keyInterval || 2.0))

  // Cursor
  args.push("-cursor", config.cursor ? "yes" : "no")

  // Audio
  if (config.audioEnabled) {
    var devices = []
    if (config.audioDesktop) devices.push("default_output")
    if (config.audioMicrophone) devices.push("default_input")
    if (devices.length > 0) {
      args.push("-a", devices.join("|"))
      args.push("-ac", streamMode ? "aac" : (config.audioCodec || "aac"))
      var ab = config.audioBitrate || 0
      if (streamMode && (ab <= 0)) ab = 128
      if (ab > 0) {
        args.push("-ab", String(ab))
      }
    }
  }

  // Streams are FLV transport.
  if (streamMode) {
    args.push("-c", "flv")
  }

  // Metadata: gsr injects its own for screen recordings by default; strip it
  // for streams (transport has no metadata channel).
  if (!streamMode) {
    args.push("-exclude-metadata", "yes")
  }

  return args
}

function normalize(raw) {
  var d = defaultConfig()
  var out = {}
  var keys = Object.keys(d)
  for (var i = 0; i < keys.length; i++) {
    var k = keys[i]
    var v = raw && raw[k] !== undefined ? raw[k] : d[k]
    if (v === null || v === undefined) v = d[k]
    if (k === "fps" || k === "keyInterval" || k === "audioBitrate") {
      v = Number(v)
      if (isNaN(v) || v < 0) v = d[k]
    }
    if (k === "streamKbps") {
      v = Number(v)
      if (isNaN(v)) v = d[k]
      if (v < 32) v = 32
      if (v > 20000) v = 20000
    }
    if (k === "cursor" || k === "audioEnabled" || k === "audioDesktop"
        || k === "audioMicrophone" || k === "advanced" || k === "showTimer"
        || k === "webcamEnabled" || k === "streamRemember"
        || k === "streamBackupLocal") {
      v = v === true || v === "true" || v === "yes" || v === 1
    }
    if (k === "mode" && ["record", "stream"].indexOf(v) === -1) v = d[k]
    if (k === "streamPlatform" && ["custom", "tiktok", "twitch", "youtube"].indexOf(v) === -1) v = d[k]
    if (k === "container" && ["mp4", "mkv", "webm", "flv", "mov"].indexOf(v) === -1) v = d[k]
    if (k === "frameMode" && ["cfr", "vfr", "content"].indexOf(v) === -1) v = d[k]
    if (k === "colorRange" && ["limited", "full"].indexOf(v) === -1) v = d[k]
    if (k === "tune" && ["performance", "quality"].indexOf(v) === -1) v = d[k]
    if (k === "encoder" && ["gpu", "cpu"].indexOf(v) === -1) v = d[k]
    out[k] = v
  }
  return out
}

function makeTimestamp() {
  var d = new Date()
  var pad = function(n) { return n < 10 ? "0" + n : String(n) }
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
    + "_" + pad(d.getHours()) + "-" + pad(d.getMinutes()) + "-" + pad(d.getSeconds())
}
