// Imports
import Quickshell.Io
import QtQuick
import ".."


Item {
  id: lyricsIsland

  required property var colors
  required property var spotifyPlayer
  required property real diagSlant
  required property real barHeight
  required property real waveformHeight

  // Playback and lyric state
  readonly property bool musicPlaying: spotifyPlayer && spotifyPlayer.isPlaying
  readonly property bool hasLyrics: currentLyric !== ""

  // Lyric line data and tracking
  property string currentLyric: ""
  property string previousLyric: ""
  property real lyricProgress: 0.0
  property var lyricLines: []
  property int lyricCurrentIdx: -1
  property bool lyricEnhanced: false
  property string lyricState: "idle"
  property bool lyricClearing: false
  property var pendingLyricData: null


  // Track position sync state
  property real syncWallTime: 0
  property real syncTrackMs: 0


  // Audio visualizer bars from cava
  property var audioBars: [0,0,0,0,0,0,0,0,0,0,0,0,0,0]

  width: 700
  visible: musicPlaying
  opacity: visible ? 1.0 : 0.0
  Behavior on opacity {
    NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
  }


  // Track position estimation and lyric clearing helpers
  function estimatedTrackMs() {
    if (syncWallTime <= 0) return 0
    return syncTrackMs + (Date.now() - syncWallTime)
  }

  function clearLyricsAnimated(pendingData) {
    if (lyricsIsland.currentLyric === "" && lyricsIsland.lyricLines.length === 0) {
      if (pendingData) lyricsIsland._loadLyricData(pendingData)
      return
    }
    lyricsIsland.lyricClearing = true
    lyricsIsland.pendingLyricData = pendingData || null
    lyricClearAnim.restart()
  }

  function _finishClear() {
    lyricsIsland.lyricLines = []
    lyricsIsland.lyricCurrentIdx = -1
    lyricsIsland.currentLyric = ""
    lyricsIsland.lyricProgress = 0.0
    lyricsIsland.syncWallTime = 0
    lyricsIsland.lyricEnhanced = false
    lyricCurrent.text = ""
    lyricCurrent.opacity = 0
    lyricOutgoing.text = ""
    lyricOutgoing.opacity = 0
    lyricsIsland.lyricClearing = false
    if (lyricsIsland.pendingLyricData) {
      lyricsIsland._loadLyricData(lyricsIsland.pendingLyricData)
      lyricsIsland.pendingLyricData = null
    }
  }

  function _loadLyricData(obj) {
    lyricsIsland.lyricLines = obj.lines
    lyricsIsland.lyricEnhanced = obj.enhanced || false
    lyricsIsland.lyricCurrentIdx = -1
    lyricsIsland.currentLyric = ""
    lyricsIsland.lyricProgress = 0.0
    lyricsIsland.launchSync()
  }

  function launchSync() {
    syncProcess.launchTime = Date.now()
    syncProcess.running = true
  }


  // Cava audio visualizer process
  Process {
    id: cavaProcess
    command: ["cava", "-p", Config.configDir + "/ext/cava/cava-bar.conf"]
    running: true
    stdout: SplitParser {
      onRead: data => {
        let raw = data.trim()
        if (!raw) return
        let vals = raw.split(";").filter(s => s !== "").map(s => parseInt(s) || 0)
        if (vals.length > 0) lyricsIsland.audioBars = vals
      }
    }
    onExited: {
      cavaRestartTimer.start()
    }
  }

  Timer {
    id: cavaRestartTimer
    interval: 2000
    onTriggered: { if (!cavaProcess.running) cavaProcess.running = true }
  }

  // Lyrics pipe reader (ytm-lyrics-pipe)
  Process {
    id: lyricsProcess
    command: [Config.scriptsDir + "/python/ytm-lyrics-pipe"]
    running: true
    stdout: SplitParser {
      onRead: data => {
        let raw = data.trim()
        if (raw === "CLEAR") {
          lyricsIsland.lyricState = "idle"
          lyricsIsland.clearLyricsAnimated(null)
          return
        }
        if (raw === "SEARCHING") {
          lyricsIsland.lyricState = "searching"
          lyricsIsland.clearLyricsAnimated(null)
          return
        }
        if (raw === "NOLYRICS") {
          lyricsIsland.lyricState = "nolyrics"
          lyricsIsland.clearLyricsAnimated(null)
          return
        }
        try {
          let obj = JSON.parse(raw)
          if (obj.lines && obj.lines.length > 0) {
            lyricsIsland.lyricState = "haslyrics"
            lyricsIsland.clearLyricsAnimated(obj)
          }
        } catch (e) {}
      }
    }
    onExited: { lyricsRestartTimer.start() }
  }

  Timer {
    id: lyricsRestartTimer
    interval: 2000
    onTriggered: {
      if (!lyricsProcess.running) {
        lyricsProcess.running = true
      }
    }
  }

  // Playerctl position sync process
  Process {
    id: syncProcess
    property string buf: ""
    property real launchTime: 0
    command: ["playerctl", "position"]
    stdout: SplitParser {
      onRead: data => { syncProcess.buf += data }
    }
    onExited: {
      let sec = parseFloat(syncProcess.buf.trim())
      syncProcess.buf = ""
      if (!isNaN(sec)) {
        let reportedMs = sec * 1000
        let wallAtRead = Date.now()

        if (lyricsIsland.syncWallTime <= 0) {
          lyricsIsland.syncTrackMs = reportedMs
          lyricsIsland.syncWallTime = wallAtRead
        } else {
          let ourEstimate = lyricsIsland.syncTrackMs + (wallAtRead - lyricsIsland.syncWallTime)
          let drift = reportedMs - ourEstimate
          if (Math.abs(drift) >= 5000) {
            lyricsIsland.syncTrackMs = reportedMs
            lyricsIsland.syncWallTime = wallAtRead
          } else if (drift > 50) {
            lyricsIsland.syncTrackMs = ourEstimate + drift * 0.4
            lyricsIsland.syncWallTime = wallAtRead
          } else if (drift < -50) {
            let corrected = ourEstimate + drift * 0.15
            let lines = lyricsIsland.lyricLines
            let idx = lyricsIsland.lyricCurrentIdx
            if (idx >= 0 && idx < lines.length && corrected < lines[idx].start) {
              corrected = lines[idx].start
            }
            lyricsIsland.syncTrackMs = corrected
            lyricsIsland.syncWallTime = wallAtRead
          }
        }
      }
    }
  }


  // Periodic position re-sync
  Timer {
    id: syncTimer
    interval: 5000
    repeat: true
    running: lyricsIsland.lyricLines.length > 0
    onTriggered: { lyricsIsland.launchSync() }
  }

  // Lyric line animation timer (word-level highlight progress)
  Timer {
    id: lyricAnimTimer
    interval: 33
    repeat: true
    running: lyricsIsland.lyricLines.length > 0 && lyricsIsland.syncWallTime > 0
    onTriggered: {
      let posMs = lyricsIsland.estimatedTrackMs()
      let lines = lyricsIsland.lyricLines

      let newIdx = -1
      for (let i = lines.length - 1; i >= 0; i--) {
        if (posMs >= lines[i].start) {
          newIdx = i
          break
        }
      }

      if (newIdx < 0) return

      let line = lines[newIdx]

      if (newIdx !== lyricsIsland.lyricCurrentIdx) {
        lyricsIsland.previousLyric = lyricsIsland.currentLyric
        lyricsIsland.currentLyric = line.text
        lyricsIsland.lyricCurrentIdx = newIdx
      }

      if (posMs > line.end) {
        lyricsIsland.lyricProgress = 1.0
      } else if (line.words && line.words.length > 0) {
        let fullText = line.text
        let charsHighlighted = 0
        let totalChars = fullText.length

        for (let w = 0; w < line.words.length; w++) {
          let word = line.words[w]
          let wordLen = word.word.length

          if (posMs < word.start) {
            break
          } else if (posMs >= word.end) {
            charsHighlighted += wordLen
            if (w < line.words.length - 1) charsHighlighted += 1
          } else {
            let wordProgress = (posMs - word.start) / (word.end - word.start)
            charsHighlighted += wordLen * wordProgress
            break
          }
        }

        lyricsIsland.lyricProgress = totalChars > 0 ? Math.max(0, Math.min(1.0, charsHighlighted / totalChars)) : 1.0
      } else {
        let duration = line.end - line.start
        lyricsIsland.lyricProgress = duration > 0 ? Math.max(0, Math.min(1.0, (posMs - line.start) / duration)) : 1.0
      }
    }
  }


  // Parallelogram background shape
  Canvas {
    id: centerBg
    anchors.fill: parent
    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)
      ctx.beginPath()
      ctx.moveTo(0, 0)
      ctx.lineTo(width, 0)
      ctx.lineTo(width - lyricsIsland.diagSlant, height)
      ctx.lineTo(lyricsIsland.diagSlant, height)
      ctx.closePath()
      ctx.fillStyle = Qt.rgba(lyricsIsland.colors.surface.r, lyricsIsland.colors.surface.g, lyricsIsland.colors.surface.b, 0.88)
      ctx.fill()
    }
    Connections {
      target: lyricsIsland.colors
      function onSurfaceChanged() { centerBg.requestPaint() }
      function onPrimaryChanged() { centerBg.requestPaint() }
    }
  }


  // Artist name label (left side)
  Text {
    id: artistLabel
    anchors.left: parent.left
    anchors.leftMargin: lyricsIsland.diagSlant + 10
    anchors.verticalCenter: parent.verticalCenter
    text: lyricsIsland.spotifyPlayer ? lyricsIsland.spotifyPlayer.trackArtist.toUpperCase() : ""
    font.pixelSize: 12
    font.weight: Font.DemiBold
    font.family: Style.fontFamily
    color: lyricsIsland.colors.primary
    elide: Text.ElideRight
    maximumLineCount: 1
    width: Math.min(implicitWidth, 120)
    visible: lyricsIsland.musicPlaying
  }


  // Track title label (right side)
  Text {
    id: trackLabel
    anchors.right: parent.right
    anchors.rightMargin: lyricsIsland.diagSlant + 10
    anchors.verticalCenter: parent.verticalCenter
    text: {
      if (!lyricsIsland.spotifyPlayer) return ""
      var t = lyricsIsland.spotifyPlayer.trackTitle
      var a = lyricsIsland.spotifyPlayer.trackArtist
      if (a && t.toLowerCase().startsWith(a.toLowerCase() + " - "))
        t = t.substring(a.length + 3)
      return t.toUpperCase()
    }
    font.pixelSize: 12
    font.weight: Font.DemiBold
    font.family: Style.fontFamily
    color: lyricsIsland.colors.primary
    elide: Text.ElideRight
    maximumLineCount: 1
    width: Math.min(implicitWidth, 120)
    horizontalAlignment: Text.AlignRight
    visible: lyricsIsland.musicPlaying
  }


  // Lyric text display container
  Item {
    id: lyricContainer
    anchors.centerIn: parent
    width: parent.width - lyricsIsland.diagSlant * 2 - 16 - (lyricsIsland.musicPlaying ? 240 : 0)
    height: parent.height
    clip: true

    property real centerY: (height - 16) / 2
    property real slideDistance: 20

    Text {
      id: lyricFallback
      visible: !lyricsIsland.hasLyrics
      width: parent.width
      y: lyricContainer.centerY
      text: {
        if (lyricsIsland.lyricState === "searching") return "RETRIEVING LYRICS..."
        if (lyricsIsland.lyricState === "nolyrics") return "NO LYRICS :("
        return ""
      }
      font.pixelSize: 12
      font.weight: Font.Medium
      font.italic: true
      font.family: Style.fontFamily
      color: Qt.rgba(lyricsIsland.colors.tertiary.r, lyricsIsland.colors.tertiary.g, lyricsIsland.colors.tertiary.b, 0.6)
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      maximumLineCount: 1
      opacity: 1
    }

    Text {
      id: lyricOutgoing
      width: parent.width
      y: lyricContainer.centerY
      text: ""
      font.pixelSize: 12
      font.weight: Font.Medium
      font.italic: true
      font.family: Style.fontFamily
      color: lyricsIsland.colors.tertiary
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      maximumLineCount: 1
      opacity: 0
    }

    Text {
      id: lyricCurrent
      width: parent.width
      y: lyricContainer.centerY
      text: ""
      font.pixelSize: 12
      font.weight: Font.Medium
      font.italic: true
      font.family: Style.fontFamily
      color: lyricsIsland.colors.tertiary
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      maximumLineCount: 1
      opacity: 1
    }


    // Word-level highlight mask for enhanced lyrics
    Item {
      id: lyricClipMask
      visible: lyricsIsland.lyricEnhanced
      x: (lyricCurrent.width - lyricCurrent.contentWidth) / 2
      y: lyricCurrent.y
      width: lyricCurrent.contentWidth * lyricsIsland.lyricProgress
      height: lyricCurrent.implicitHeight
      clip: true

      Text {
        id: lyricHighlight
        x: -lyricClipMask.x
        y: 0
        width: lyricContainer.width
        text: lyricsIsland.currentLyric
        font: lyricCurrent.font
        color: lyricsIsland.colors.primary
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        maximumLineCount: 1
      }
    }

    // Lyric transition animations
    ParallelAnimation {
      id: outgoingAnim
      NumberAnimation {
        target: lyricOutgoing; property: "y"
        to: lyricContainer.centerY - lyricContainer.slideDistance
        duration: 250; easing.type: Easing.OutCubic
      }
      NumberAnimation {
        target: lyricOutgoing; property: "opacity"
        to: 0.0
        duration: 250; easing.type: Easing.OutCubic
      }
    }

    ParallelAnimation {
      id: incomingAnim
      NumberAnimation {
        target: lyricCurrent; property: "y"
        to: lyricContainer.centerY
        duration: 300; easing.type: Easing.OutCubic
      }
      NumberAnimation {
        target: lyricCurrent; property: "opacity"
        to: 1.0
        duration: 300; easing.type: Easing.OutCubic
      }
    }

    ParallelAnimation {
      id: lyricClearAnim
      NumberAnimation {
        target: lyricCurrent; property: "opacity"
        to: 0.0; duration: 300; easing.type: Easing.OutCubic
      }
      NumberAnimation {
        target: lyricCurrent; property: "y"
        to: lyricContainer.centerY - lyricContainer.slideDistance
        duration: 300; easing.type: Easing.OutCubic
      }
      NumberAnimation {
        target: lyricOutgoing; property: "opacity"
        to: 0.0; duration: 200; easing.type: Easing.OutCubic
      }
      onFinished: lyricsIsland._finishClear()
    }

    Connections {
      target: lyricsIsland
      function onCurrentLyricChanged() {
        if (lyricsIsland.currentLyric === "") return
        outgoingAnim.stop()
        incomingAnim.stop()
        lyricOutgoing.text = lyricCurrent.text
        lyricOutgoing.y = lyricContainer.centerY
        lyricOutgoing.opacity = 1.0
        lyricCurrent.text = lyricsIsland.currentLyric
        lyricCurrent.y = lyricContainer.centerY + lyricContainer.slideDistance
        lyricCurrent.opacity = 0.0
        outgoingAnim.restart()
        incomingAnim.restart()
      }
    }
  }


  // Upper waveform canvas (inside bar area)
  Canvas {
    id: audioVisualizerUp
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: lyricsIsland.waveformHeight

    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)

      var raw = audioVisualizer.displayBars
      if (!raw || raw.length === 0) return

      var first = raw[0] || 0
      var last = raw[raw.length - 1] || 0
      var vals = [0, first * 0.1, first * 0.35]
        .concat(raw)
        .concat([last * 0.35, last * 0.1, 0])

      var baseY = height
      var maxAmp = height

      var slant = lyricsIsland.diagSlant
      var islandH = lyricsIsland.barHeight
      var topFrac = (islandH - height) / islandH
      var botFrac = 1.0
      var leftAtTop = slant * topFrac
      var leftAtBot = slant * botFrac
      var rightAtTop = width - slant * topFrac
      var rightAtBot = width - slant * botFrac

      ctx.save()
      ctx.beginPath()
      ctx.moveTo(leftAtTop, 0)
      ctx.lineTo(rightAtTop, 0)
      ctx.lineTo(rightAtBot, height)
      ctx.lineTo(leftAtBot, height)
      ctx.closePath()
      ctx.clip()

      var step = width / (vals.length - 1)

      var pri = lyricsIsland.colors.primary
      ctx.beginPath()
      ctx.moveTo(0, baseY)
      for (var i = 0; i < vals.length; i++) {
        var x = i * step
        var y = baseY - (vals[i] / 100) * maxAmp
        if (i === 0) {
          ctx.lineTo(x, y)
        } else {
          var prevX = (i - 1) * step
          var cpX = (prevX + x) / 2
          var prevY = baseY - (vals[i-1] / 100) * maxAmp
          ctx.quadraticCurveTo(cpX, prevY, x, y)
        }
      }
      ctx.lineTo(width, baseY)
      ctx.closePath()

      var grad = ctx.createLinearGradient(0, baseY, 0, baseY - maxAmp)
      grad.addColorStop(0, Qt.rgba(pri.r, pri.g, pri.b, 0.25))
      grad.addColorStop(0.6, Qt.rgba(pri.r, pri.g, pri.b, 0.08))
      grad.addColorStop(1, Qt.rgba(pri.r, pri.g, pri.b, 0.0))
      ctx.fillStyle = grad
      ctx.fill()

      var ter = lyricsIsland.colors.tertiary
      ctx.beginPath()
      ctx.moveTo(0, baseY)
      for (var j = 0; j < vals.length; j++) {
        var lx = j * step
        var ly = baseY - (vals[j] / 100) * maxAmp
        if (j === 0) {
          ctx.lineTo(lx, ly)
        } else {
          var lpx = (j - 1) * step
          var lcpx = (lpx + lx) / 2
          ctx.quadraticCurveTo(lcpx, baseY - (vals[j-1] / 100) * maxAmp, lx, ly)
        }
      }
      ctx.lineTo(width, baseY)
      ctx.strokeStyle = Qt.rgba(ter.r, ter.g, ter.b, 0.2)
      ctx.lineWidth = 1
      ctx.stroke()

      ctx.restore()
    }

    Connections {
      target: audioVisualizer
      function onDisplayBarsChanged() { audioVisualizerUp.requestPaint() }
    }
    Connections {
      target: lyricsIsland.colors
      function onPrimaryChanged() { audioVisualizerUp.requestPaint() }
      function onTertiaryChanged() { audioVisualizerUp.requestPaint() }
    }
  }


  // Lower waveform canvas (below bar, with smoothed bars)
  Canvas {
    id: audioVisualizer
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.bottom
    height: lyricsIsland.waveformHeight
    property var displayBars: [0,0,0,0,0,0,0,0,0,0,0,0,0,0]

    Connections {
      target: lyricsIsland
      function onAudioBarsChanged() {
        let newBars = lyricsIsland.audioBars
        let smoothed = []
        let prev = audioVisualizer.displayBars
        for (let i = 0; i < newBars.length; i++) {
          let p = i < prev.length ? prev[i] : 0
          smoothed.push(p + (newBars[i] - p) * 0.45)
        }
        audioVisualizer.displayBars = smoothed
        audioVisualizer.requestPaint()
      }
    }

    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)

      var raw = displayBars
      if (!raw || raw.length === 0) return

      var first = raw[0] || 0
      var last = raw[raw.length - 1] || 0
      var vals = [0, first * 0.1, first * 0.35]
        .concat(raw)
        .concat([last * 0.35, last * 0.1, 0])

      var baseY = 0
      var maxAmp = height
      var step = width / (vals.length - 1)

      var slant = lyricsIsland.diagSlant

      ctx.save()
      ctx.beginPath()
      ctx.moveTo(slant, 0)
      ctx.lineTo(width - slant, 0)
      ctx.lineTo(width, height)
      ctx.lineTo(0, height)
      ctx.closePath()
      ctx.clip()

      var surf = lyricsIsland.colors.surface
      ctx.beginPath()
      ctx.moveTo(0, baseY)
      for (var i = 0; i < vals.length; i++) {
        var x = i * step
        var y = baseY + (vals[i] / 100) * maxAmp
        if (i === 0) {
          ctx.lineTo(x, y)
        } else {
          var prevX = (i - 1) * step
          var cpX = (prevX + x) / 2
          var prevY = baseY + (vals[i-1] / 100) * maxAmp
          ctx.quadraticCurveTo(cpX, prevY, x, y)
        }
      }
      ctx.lineTo(width, baseY)
      ctx.closePath()
      ctx.fillStyle = Qt.rgba(surf.r, surf.g, surf.b, 0.88)
      ctx.fill()

      var pri = lyricsIsland.colors.primary
      ctx.beginPath()
      ctx.moveTo(0, baseY)
      for (var j = 0; j < vals.length; j++) {
        var lx = j * step
        var ly = baseY + (vals[j] / 100) * maxAmp
        if (j === 0) {
          ctx.lineTo(lx, ly)
        } else {
          var lpx = (j - 1) * step
          var lcpx = (lpx + lx) / 2
          ctx.quadraticCurveTo(lcpx, baseY + (vals[j-1] / 100) * maxAmp, lx, ly)
        }
      }
      ctx.lineTo(width, baseY)
      ctx.strokeStyle = Qt.rgba(pri.r, pri.g, pri.b, 0.3)
      ctx.lineWidth = 1
      ctx.stroke()

      ctx.restore()
    }

    Connections {
      target: lyricsIsland.colors
      function onSurfaceChanged() { audioVisualizer.requestPaint() }
      function onPrimaryChanged() { audioVisualizer.requestPaint() }
    }
  }
}
