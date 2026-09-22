.pragma library

// pix.recast GPU and encoder detection.
// Primary source: `gpu-screen-recorder --info` (authoritative for what gsr supports).
// Fallback: nvidia-smi for NVIDIA detail, DRM/sysfs for AMD/Intel info.

function parseGsrInfo(text) {
  var info = { vendor: "unknown", cardPath: "", codecs: [], driverVersion: "", backend: "cpu" }
  var lines = String(text || "").split("\n")
  var section = ""
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "section=gpu_info") { section = "gpu"; continue }
    if (line === "section=video_codecs") { section = "codecs"; continue }
    if (line.indexOf("section=") === 0) { section = ""; continue }
    if (section === "gpu") {
      if (line.indexOf("vendor|") === 0) info.vendor = line.substring(7).trim()
      if (line.indexOf("card_path|") === 0) info.cardPath = line.substring(10).trim()
    }
    if (section === "codecs") {
      if (line && line !== "h264_software") info.codecs.push(line)
      else if (line === "h264_software") info.codecs.push("h264_software")
    }
  }
  if (info.vendor === "nvidia") info.backend = "nvenc"
  else if (info.vendor === "amd") info.backend = "vaapi"
  else if (info.vendor === "intel") info.backend = "vaapi"
  return info
}

function parseMonitorList(text) {
  var monitors = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("|")
    if (parts.length >= 2) {
      monitors.push({ name: parts[0].trim(), resolution: parts[1].trim() })
    }
  }
  return monitors
}

function parseAudioDevices(text) {
  var devices = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("|")
    if (parts.length >= 2) {
      devices.push({ id: parts[0].trim(), name: (parts[1] || parts[0]).trim() })
    }
  }
  return devices
}

function parseV4L2Devices(text) {
  var devices = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line || line.indexOf("/dev/") !== 0) continue
    var parts = line.split("|")
    devices.push({ path: parts[0].trim(), name: parts.length > 1 && parts[1].trim() ? parts[1].trim() : parts[0].trim() })
  }
  if (devices.length === 0)
    devices.push({ path: "", name: "No webcam found" })
  return devices
}
