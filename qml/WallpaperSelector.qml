import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import QtQuick.Controls
import QtQuick.Shapes
import QtMultimedia

// Wallpaper picker with parallelogram slices, ollama AI tagging, color/tag/type filtering
Scope {
  id: wallpaperSelector

  // External bindings
  property var colors
  property bool showing: false


  property string mainMonitor: Config.mainMonitor


  signal wallpaperChanged()


  function resetScroll() {
    wallpaperSelector.lastContentX = 0
    wallpaperSelector.lastIndex = 0
    sliceListView.currentIndex = 0
    if (filteredModel.count > 0)
      sliceListView.positionViewAtIndex(0, ListView.Beginning)
  }


  // Show/hide lifecycle (reset ollama state, check cache)
  onShowingChanged: {
    if (showing) {
      ollamaTaggingActive = false
      ollamaColorsActive = false
      ollamaEta = ""
      ollamaStartTime = 0
      ollamaLogLine = ""

      wallpaperSelector.cacheResult = ""
      checkCache.running = true

      cardShowTimer.restart()
    } else {
      cardVisible = false
    }
  }


  // Cache mtime check (reload wallpaper list if cache changed)
  Process {
    id: cacheStatCheck
    command: ["stat", "-c", "%Y", wallpaperSelector.wallpaperListCache]
    property string result: ""
    onRunningChanged: { if (running) result = "" }
    stdout: SplitParser {
      onRead: line => { cacheStatCheck.result = line.trim() }
    }
    onExited: {
      var mtime = cacheStatCheck.result
      if (mtime === "") {
        return
      }
      if (wallpaperModel.count === 0 || mtime !== wallpaperSelector.lastCacheMtime) {
        wallpaperSelector.lastCacheMtime = mtime
        wallpaperModel.clear()
        listWallpapers.running = true
      }
    }
  }

  Timer {
    id: cardShowTimer
    interval: 50
    onTriggered: wallpaperSelector.cardVisible = true
  }


  // Ollama analysis status polling
  Timer {
    id: ollamaStatusTimer
    interval: Config.ollamaStatusPollMs
    running: wallpaperSelector.showing
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      ollamaStatusCheck.running = true
      ollamaProgressCheck.running = true
      if (wallpaperSelector.ollamaActive) {
        ollamaLogCheck.running = true
      }
    }
  }


  // Live-reload metadata while ollama is analyzing
  Timer {
    id: liveReloadTimer
    interval: 15000
    running: wallpaperSelector.showing && wallpaperSelector.ollamaActive
    repeat: true
    onTriggered: {
      reloadMetadata()
    }
  }


  // Ollama analysis log tail reader
  Process {
    id: ollamaLogCheck
    command: ["bash", "-c", "tail -n1 " + Config.cacheDir + "/analyze-wallpapers.log 2>/dev/null | cut -c1-120"]
    running: false
    stdout: SplitParser {
      onRead: line => {
        var trimmed = line.trim()
        if (trimmed && trimmed.length > 0) {
          wallpaperSelector.ollamaLogLine = trimmed
        }
      }
    }
  }


  // Ollama process active/idle detection
  Process {
    id: ollamaStatusCheck
    command: ["bash", "-c", "pgrep -f 'analyze-wallpapers' > /dev/null && echo 'active' || echo 'idle'"]
    property string result: ""
    stdout: SplitParser {
      onRead: line => {
        ollamaStatusCheck.result = line.trim()
      }
    }
    onRunningChanged: {
      if (running) result = ""
    }
    onExited: {
      if (result === "active") {
        ollamaDetailCheck.running = true
      } else {
        wallpaperSelector.ollamaTaggingActive = false
        wallpaperSelector.ollamaColorsActive = false
        wallpaperSelector.ollamaLogLine = ""
      }
    }
  }

  Process {
    id: ollamaDetailCheck
    command: ["bash", "-c", "pgrep -f '[a]nalyze-wallpapers' > /dev/null && echo 'tag:1:color:1' || echo 'tag:0:color:0'"]
    stdout: SplitParser {
      onRead: line => {
        var parts = line.trim().split(":")
        if (parts.length >= 4) {
          wallpaperSelector.ollamaTaggingActive = (parts[1] === "1")
          wallpaperSelector.ollamaColorsActive = (parts[3] === "1")
        }
      }
    }
  }

  // Ollama progress tracking (thumbs, tagged, colored counts + ETA)
  Process {
    id: ollamaProgressCheck
    command: ["bash", "-c", `
      thumbs=$(( $(find ~/.cache/piixident/wallpaper/thumbs -name '*.jpg' 2>/dev/null | wc -l) + $(find ~/.cache/piixident/wallpaper/we-thumbs -name '*.jpg' 2>/dev/null | wc -l) + $(find ~/.cache/piixident/wallpaper/video-thumbs -name '*.jpg' 2>/dev/null | wc -l) ))
      tags=$(jq 'keys | length' ~/.cache/piixident/wallpaper/tags.json 2>/dev/null || echo 0)
      colors=$(jq 'keys | length' ~/.cache/piixident/wallpaper/colors.json 2>/dev/null || echo 0)
      echo "$thumbs:$tags:$colors"
    `]
    stdout: SplitParser {
      onRead: line => {
        var parts = line.trim().split(":")
        if (parts.length >= 3) {
          var total = parseInt(parts[0]) || 0
          var tagged = parseInt(parts[1]) || 0
          var colored = parseInt(parts[2]) || 0

          wallpaperSelector.ollamaTotalThumbs = total
          wallpaperSelector.ollamaTaggedCount = tagged
          wallpaperSelector.ollamaColoredCount = colored

          if (!wallpaperSelector.ollamaActive) {
            wallpaperSelector.ollamaStartTime = 0
            wallpaperSelector.ollamaEta = ""
            return
          }

          var now = Date.now() / 1000

          if (wallpaperSelector.ollamaStartTime === 0) {
            wallpaperSelector.ollamaStartTime = now
            wallpaperSelector.ollamaStartTagCount = tagged
            wallpaperSelector.ollamaStartColorCount = colored
            wallpaperSelector.ollamaEta = "starting..."
            return
          }

          var elapsed = now - wallpaperSelector.ollamaStartTime
          if (elapsed < 8) {
            wallpaperSelector.ollamaEta = "calculating..."
            return
          }

          var processed = 0
          var remaining = 0

          if (wallpaperSelector.ollamaTaggingActive && wallpaperSelector.ollamaColorsActive) {
            var tagRemaining = total - tagged
            var colorRemaining = total - colored
            remaining = tagRemaining + colorRemaining
            processed = (tagged - wallpaperSelector.ollamaStartTagCount) + (colored - wallpaperSelector.ollamaStartColorCount)
          } else if (wallpaperSelector.ollamaTaggingActive) {
            processed = tagged - wallpaperSelector.ollamaStartTagCount
            remaining = total - tagged
          } else if (wallpaperSelector.ollamaColorsActive) {
            processed = colored - wallpaperSelector.ollamaStartColorCount
            remaining = total - colored
          }

          if (processed > 0 && remaining > 0) {
            var rate = processed / elapsed
            var etaSeconds = remaining / rate

            if (etaSeconds < 60) {
              wallpaperSelector.ollamaEta = "~" + Math.round(etaSeconds) + "s"
            } else if (etaSeconds < 3600) {
              wallpaperSelector.ollamaEta = "~" + Math.round(etaSeconds / 60) + "m"
            } else {
              var hours = Math.floor(etaSeconds / 3600)
              var mins = Math.round((etaSeconds % 3600) / 60)
              wallpaperSelector.ollamaEta = "~" + hours + "h" + mins + "m"
            }
          } else if (remaining === 0) {
            if (tagged >= total && colored >= total && total > 0) {
              ollamaFinalCheck.running = true
            } else {
              wallpaperSelector.ollamaEta = "finishing..."
            }
          } else {
            wallpaperSelector.ollamaEta = "calculating..."
          }
        }
      }
    }
  }

  Process {
    id: ollamaFinalCheck
    command: ["bash", "-c", "pgrep -f '[t]ag-wallpapers|[a]nalyze-wallpaper-colors' > /dev/null && echo 'active' || echo 'idle'"]
    stdout: SplitParser {
      onRead: line => {
        if (line.trim() === "idle") {
          wallpaperSelector.ollamaTaggingActive = false
          wallpaperSelector.ollamaColorsActive = false
          wallpaperSelector.ollamaEta = ""
          wallpaperSelector.ollamaStartTime = 0
          wallpaperSelector.ollamaLogLine = ""
        } else {
          wallpaperSelector.ollamaEta = "finishing..."
        }
      }
    }
  }


  Timer {
    id: focusTimer
    interval: 50
    onTriggered: sliceListView.forceActiveFocus()
  }


  // Slice geometry constants
  property int sliceWidth: 135
  property int expandedWidth: 924
  property int sliceHeight: 520
  property int skewOffset: 35
  property int sliceSpacing: -22


  property string homeDir: Config.homeDir


  property string scriptsDir: Config.scriptsDir


  // Wallpaper directory paths
  property string wallDir: Config.wallpaperDir
  property string cacheDir: Config.cacheDir + "/wallpaper/thumbs"
  property string weCache: Config.cacheDir + "/wallpaper/we-thumbs"
  property string weDir: Config.weDir
  property string weAssets: Config.weAssetsDir
  property string weListCache: Config.cacheDir + "/wallpaper/we-list.txt"


  property int cardWidth: 1600
  property int topBarHeight: 50
  property bool tagCloudVisible: false
  property int tagCloudHeight: tagCloudVisible ? 120 : 0
  property int cardHeight: sliceHeight + topBarHeight + tagCloudHeight + 60


  property string wallpaperListCache: Config.cacheDir + "/wallpaper/list.jsonl"


  property string lastCacheMtime: ""


  property bool cacheReady: false
  property string cacheResult: ""


  property int cacheProgress: 0
  property int cacheTotal: 0
  property bool cacheLoading: false


  // Filter and sort state
  property int selectedColorFilter: -1


  property string selectedTypeFilter: ""


  property string sortMode: "color"


  property var selectedTags: []
  property int selectedTagIndex: -1


  property var popularTags: []


  // Tags and colors metadata databases
  property var tagsDb: ({})


  property var colorsDb: ({})


  property string tagsFile: Config.cacheDir + "/wallpaper/tags.json"


  property string colorsFile: Config.cacheDir + "/wallpaper/colors.json"


  property var matugenDb: ({})


  property string matugenFile: Config.cacheDir + "/wallpaper/matugen-colors.json"


  FileView { id: tagsFileView; path: wallpaperSelector.tagsFile; preload: true }
  FileView { id: colorsFileView; path: wallpaperSelector.colorsFile; preload: true }
  FileView { id: matugenFileView; path: wallpaperSelector.matugenFile; preload: true }

  // Reload tags, colors, and matugen metadata from JSON files
  function reloadMetadata() {

    try {
      var text = tagsFileView.text()
      if (text.length > 0) {
        wallpaperSelector.tagsDb = JSON.parse(text)
        var tagCounts = {}
        for (var name in wallpaperSelector.tagsDb) {
          var tags = wallpaperSelector.tagsDb[name]
          for (var i = 0; i < tags.length; i++) {
            var tag = tags[i]
            tagCounts[tag] = (tagCounts[tag] || 0) + 1
          }
        }
        var tagArray = []
        for (var t in tagCounts) {
          tagArray.push({tag: t, count: tagCounts[t]})
        }
        tagArray.sort(function(a, b) { return b.count - a.count })
        wallpaperSelector.popularTags = tagArray
      }
    } catch (e) { console.log("Error parsing tags JSON:", e) }

    try {
      var cText = colorsFileView.text()
      if (cText.length > 0) {
        wallpaperSelector.colorsDb = JSON.parse(cText)
        wallpaperSelector.updateFilteredModel()
      }
    } catch (e) { console.log("Error parsing colors JSON:", e) }

    try {
      var mText = matugenFileView.text()
      if (mText.length > 0) {
        wallpaperSelector.matugenDb = JSON.parse(mText)
      }
    } catch (e) { console.log("Error parsing matugen JSON:", e) }
  }


  property real lastContentX: 0
  property int lastIndex: 0


  property bool cardVisible: false


  // Ollama analysis state
  property bool ollamaTaggingActive: false
  property bool ollamaColorsActive: false
  property bool ollamaActive: ollamaTaggingActive || ollamaColorsActive
  property int ollamaTotalThumbs: 0
  property int ollamaTaggedCount: 0
  property int ollamaColoredCount: 0


  property real ollamaStartTime: 0
  property int ollamaStartTagCount: 0
  property int ollamaStartColorCount: 0
  property string ollamaEta: ""
  property string ollamaLogLine: ""


  // Wallpaper data models
  ListModel {
    id: wallpaperModel
  }


  ListModel {
    id: filteredModel
  }


  // Filter and sort wallpapers by type, color, tags, and sort mode
  function updateFilteredModel() {
    function baseName(filename) {
      var dot = filename.lastIndexOf('.')
      return dot > 0 ? filename.substring(0, dot) : filename
    }

    var items = []
    for (var i = 0; i < wallpaperModel.count; i++) {
      var item = wallpaperModel.get(i)
      var itemBaseName = baseName(item.name)
      var lookupKey = item.weId ? item.weId : itemBaseName

      var hue = item.hue
      var saturation = item.saturation || 0

      if (selectedTypeFilter !== "" && item.type !== selectedTypeFilter) continue
      if (selectedColorFilter !== -1 && hue !== selectedColorFilter) continue

      if (selectedTags.length > 0) {
        var wallpaperTags = tagsDb[lookupKey]
        if (!wallpaperTags) continue
        var allTagsMatch = true
        for (var t = 0; t < selectedTags.length; t++) {
          if (wallpaperTags.indexOf(selectedTags[t]) === -1) {
            allTagsMatch = false
            break
          }
        }
        if (!allTagsMatch) continue
      }

      items.push({
        name: item.name,
        type: item.type,
        thumb: item.thumb,
        path: item.path,
        weId: item.weId,
        videoFile: item.videoFile,
        mtime: item.mtime,
        hue: hue,
        saturation: saturation
      })
    }

    if (wallpaperSelector.sortMode === "date") {
      items.sort(function(a, b) { return b.mtime - a.mtime })
    } else {
      items.sort(function(a, b) {
        var hueA = a.hue === 99 ? 100 : a.hue
        var hueB = b.hue === 99 ? 100 : b.hue
        if (hueA !== hueB) return hueA - hueB
        return b.saturation - a.saturation
      })
    }

    filteredModel.clear()
    for (var j = 0; j < items.length; j++) {
      filteredModel.append(items[j])
    }


    if (filteredModel.count > 0) {
      sliceListView.currentIndex = 0
      sliceListView.positionViewAtIndex(0, ListView.Beginning)
    }
  }

  onSelectedColorFilterChanged: updateFilteredModel()
  onSelectedTypeFilterChanged: updateFilteredModel()


  // Cache checker process (scans wallpaper dirs, generates thumbnails)
  Process {
    id: checkCache
    command: [wallpaperSelector.scriptsDir + "/bash/check-wallpaper-cache"]
    onRunningChanged: {
      if (running) {
        wallpaperSelector.cacheLoading = true
        wallpaperSelector.cacheProgress = 0
        wallpaperSelector.cacheTotal = 0
      }
    }
    stdout: SplitParser {
      onRead: line => {
        if (line.startsWith("progress:")) {
          const parts = line.split(":")
          if (parts.length === 3) {
            wallpaperSelector.cacheProgress = parseInt(parts[1])
            wallpaperSelector.cacheTotal = parseInt(parts[2])
          }
        } else if (line === "regenerated" || line === "cached") {
          wallpaperSelector.cacheResult = line
        }
      }
    }
    onExited: {
      wallpaperSelector.cacheReady = true
      wallpaperSelector.cacheLoading = false
      if (wallpaperSelector.cacheResult === "regenerated" || wallpaperModel.count === 0) {
        wallpaperModel.clear()
        listWallpapers.running = true
      } else {
        reloadMetadata()
      }
    }
  }

  // JSONL wallpaper list loader
  Process {
    id: listWallpapers
    command: ["bash", "-c",
      "if [ -f '" + wallpaperSelector.wallpaperListCache + "' ]; then cat '" + wallpaperSelector.wallpaperListCache + "'; fi"
    ]
    running: false
    onRunningChanged: {
      if (!running) {
        wallpaperSelector.updateFilteredModel()
      }
    }
    stdout: SplitParser {
      onRead: line => {
        try {
          var obj = JSON.parse(line)
          wallpaperModel.append({
            name: obj.name,
            type: obj.type,
            thumb: obj.thumb,
            path: (obj.type === "static" || obj.type === "video") ? wallpaperSelector.wallDir + "/" + obj.name : "",
            weId: obj.type === "we" ? obj.id : "",
            videoFile: obj.videoFile || "",
            mtime: obj.mtime,
            hue: obj.group,
            saturation: obj.sat
          })
        } catch (e) {}
      }
    }
    onExited: {
      reloadMetadata()
    }
  }


  // Wallpaper apply processes (static, WE, video)
  Process {
    id: applyWallpaper
    command: ["bash", "-c", "true"]
    onExited: function(code, status) {
      if (code === 0) wallpaperSelector.wallpaperChanged()
    }
    function apply(path) {
      command = [wallpaperSelector.scriptsDir + "/bash/apply-static-wallpaper", path]
      running = true
    }
  }

  Process {
    id: applyWEWallpaper
    command: ["bash", "-c", "true"]
    function apply(id) {
      command = [wallpaperSelector.scriptsDir + "/bash/apply-we-wallpaper", id]
      running = true
    }
  }

  Process {
    id: applyVideoWallpaper
    command: ["bash", "-c", "true"]
    function apply(path) {
      command = [wallpaperSelector.scriptsDir + "/bash/apply-video-wallpaper", path]
      running = true
    }
  }

  // Delete wallpaper and clear cache
  Process {
    id: deleteWallpaper
    command: ["bash", "-c", "true"]
    function remove(type, name, weId) {
      if (type === "we") {
        command = ["rm", "-rf", wallpaperSelector.weDir + "/" + weId]
      } else {
        command = ["rm", "-f", wallpaperSelector.wallDir + "/" + name]
      }
      running = true
    }
    onExited: { clearCache.running = true }
  }

  Process {
    id: clearCache
    command: ["rm", "-f", Config.cacheDir + "/wallpaper/checksum.txt"]
    onExited: {
      wallpaperSelector.cacheReady = false
      wallpaperModel.clear()
    }
  }

  Process {
    id: unsubscribeWE
    command: ["bash", "-c", "true"]
    function unsubscribe(weId) {
      command = ["xdg-open", "steam://url/CommunityFilePage/" + weId]
      running = true
    }
  }


  // Right-click context menu state
  property string contextMenuName: ""
  property string contextMenuType: ""
  property string contextMenuWeId: ""
  property string contextMenuPath: ""
  property real contextMenuX: 0
  property real contextMenuY: 0
  property bool contextMenuVisible: false


  // Full-screen overlay panel
  PanelWindow {
    id: selectorPanel

    screen: Quickshell.screens.find(s => s.name === wallpaperSelector.mainMonitor) ?? Quickshell.screens[0]

    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }
    margins {
      top: 0
      bottom: 0
      left: 0
      right: 0
    }

    visible: wallpaperSelector.showing
    color: "transparent"

    WlrLayershell.namespace: "wallpaper-selector-parallel"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: wallpaperSelector.showing ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    exclusionMode: ExclusionMode.Ignore


    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.5)
      opacity: wallpaperSelector.cardVisible ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 300 } }
    }


    MouseArea {
      anchors.fill: parent
      onClicked: wallpaperSelector.showing = false
    }


  // Card container with fade-in
  Item {
    id: cardContainer
    width: wallpaperSelector.cardWidth
    height: wallpaperSelector.cardHeight
    anchors.centerIn: parent
    visible: wallpaperSelector.cardVisible


    opacity: 0
    property bool animateIn: wallpaperSelector.cardVisible

    onAnimateInChanged: {
      fadeInAnim.stop()
      if (animateIn) {
        opacity = 0
        fadeInAnim.start()
        focusTimer.restart()
      }
    }

    NumberAnimation {
      id: fadeInAnim
      target: cardContainer
      property: "opacity"
      from: 0; to: 1
      duration: 400
      easing.type: Easing.OutCubic
    }

    MouseArea {
      anchors.fill: parent
      onClicked: {}
    }


    // Ollama analysis status indicator (top-right)
    Rectangle {
      id: ollamaStatusIndicator
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: 8
      anchors.rightMargin: 8
      z: 100

      visible: wallpaperSelector.ollamaActive
      opacity: wallpaperSelector.ollamaActive ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 200 } }

      width: Math.max(ollamaStatusRow.width + 20, ollamaLogText.width + 20)
      height: wallpaperSelector.ollamaLogLine ? 44 : 28
      radius: height / 2
      color: wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.surfaceContainer.r, wallpaperSelector.colors.surfaceContainer.g, wallpaperSelector.colors.surfaceContainer.b, 0.9) : Qt.rgba(0.1, 0.12, 0.18, 0.9)

      layer.enabled: false

      Column {
        anchors.centerIn: parent
        spacing: 2

        Row {
          id: ollamaStatusRow
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: 6

          Text {
            text: "󰔟"
            font.family: Style.fontFamilyNerdIcons
            font.pixelSize: 14
            color: wallpaperSelector.colors ? wallpaperSelector.colors.primary : "#8BC34A"
            RotationAnimation on rotation {
              from: 0; to: 360; duration: 1000
              loops: Animation.Infinite
              running: wallpaperSelector.ollamaActive
            }
          }

          Text {
            text: {
              var status = "ANALYZING"
              var progress = ""
              if (wallpaperSelector.ollamaTotalThumbs > 0) {
                progress = " " + wallpaperSelector.ollamaTaggedCount + "/" + wallpaperSelector.ollamaTotalThumbs
              }
              var eta = wallpaperSelector.ollamaEta
              if (eta && eta !== "") return status + progress + " (" + eta + ")"
              return status + progress
            }
            font.family: Style.fontFamily
            font.pixelSize: 11
            font.weight: Font.Medium
            font.letterSpacing: 0.5
            color: wallpaperSelector.colors ? wallpaperSelector.colors.tertiary : "#8bceff"
          }
        }

        Text {
          id: ollamaLogText
          anchors.horizontalCenter: parent.horizontalCenter
          text: wallpaperSelector.ollamaLogLine
          visible: wallpaperSelector.ollamaLogLine !== ""
          font.family: Style.fontFamilyCode
          font.pixelSize: 9
          color: wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.surfaceText.r, wallpaperSelector.colors.surfaceText.g, wallpaperSelector.colors.surfaceText.b, 0.6) : Qt.rgba(1, 1, 1, 0.5)
          elide: Text.ElideMiddle
          maximumLineCount: 1
        }
      }
    }


  // Card contents (filter bar, tag cloud, context menu, progress)
  Item {
    id: backgroundRect
    anchors.fill: parent

    // Top filter bar background pill
    Rectangle {
      id: filterBarBg
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: 10
      width: topFilterBar.width + 30
      height: topFilterBar.height + 14
      radius: height / 2
      color: wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.surfaceContainer.r,
                                                 wallpaperSelector.colors.surfaceContainer.g,
                                                 wallpaperSelector.colors.surfaceContainer.b, 0.85)
                                      : Qt.rgba(0.1, 0.12, 0.18, 0.85)
      z: 10
    }

    // Top filter bar (type, color dots, sort, count)
    Row {
      id: topFilterBar
      anchors.centerIn: filterBarBg
      spacing: 20
      z: 11


      Row {
        id: typeFilterRow
        spacing: 4

        Repeater {
          model: [
            { type: "", icon: "󰄶", label: "All" },
            { type: "static", icon: "󰋩", label: "Pic" },
            { type: "video", icon: "󰕧", label: "Vid" },
            { type: "we", icon: "󰖔", label: "WE" }
          ]

          Rectangle {
            width: 32
            height: 24
            radius: 4
            property bool isSelected: wallpaperSelector.selectedTypeFilter === modelData.type
            property bool isHovered: typeMouseArea.containsMouse

            color: isSelected
              ? (wallpaperSelector.colors ? wallpaperSelector.colors.primary : "#4fc3f7")
              : (isHovered
                ? (wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.surfaceVariant.r, wallpaperSelector.colors.surfaceVariant.g, wallpaperSelector.colors.surfaceVariant.b, 0.5) : Qt.rgba(1, 1, 1, 0.15))
                : "transparent")

            border.width: isSelected ? 0 : 1
            border.color: isHovered ? (wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.primary.r, wallpaperSelector.colors.primary.g, wallpaperSelector.colors.primary.b, 0.4) : Qt.rgba(1, 1, 1, 0.2)) : "transparent"

            Behavior on color { ColorAnimation { duration: 100 } }
            Behavior on border.color { ColorAnimation { duration: 100 } }

            Text {
              anchors.centerIn: parent
              text: modelData.icon
              font.pixelSize: 14
              font.family: Style.fontFamilyNerdIcons
              color: parent.isSelected
                ? (wallpaperSelector.colors ? wallpaperSelector.colors.primaryText : "#000")
                : (wallpaperSelector.colors ? wallpaperSelector.colors.tertiary : "#8bceff")
            }

            MouseArea {
              id: typeMouseArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (parent.isSelected) {
                  wallpaperSelector.selectedTypeFilter = ""
                } else {
                  wallpaperSelector.selectedTypeFilter = modelData.type
                }
              }
            }

            ToolTip {
              visible: typeMouseArea.containsMouse
              text: modelData.label
              delay: 500
            }
          }
        }
      }


      Rectangle {
        width: 1; height: 20
        color: wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.primary.r, wallpaperSelector.colors.primary.g, wallpaperSelector.colors.primary.b, 0.3) : Qt.rgba(1, 1, 1, 0.2)
      }


      // Color hue filter (parallelogram dots)
      Row {
        id: colorDotsRow
        spacing: -5

        Repeater {
          model: 13

          Item {
            width: 38; height: 20
            readonly property int filterValue: index < 12 ? index : 99
            readonly property bool isSelected: wallpaperSelector.selectedColorFilter === filterValue
            readonly property color shapeColor: index === 12 ? "#777" : Qt.hsla(index / 12.0, 0.7, 0.5, 1.0)
            readonly property color shadowColor: index === 12 ? "#555" : Qt.hsla(index / 12.0, 0.8, 0.3, 1.0)

            Canvas {
              id: colorCanvas
              anchors.centerIn: parent
              width: parent.width; height: parent.height
              scale: parent.isSelected ? 1.15 : 1.0
              Behavior on scale { NumberAnimation { duration: 100; easing.type: Easing.OutBack } }

              property color fillColor: parent.shapeColor
              property color borderColor: index === 12 ? "#aaa" : Qt.hsla(index / 12.0, 0.7, 0.75, 1.0)
              property color dropShadowColor: parent.shadowColor
              property real fillOpacity: parent.isSelected ? 1.0 : 0.6
              property bool showShadow: parent.isSelected

              onFillColorChanged: requestPaint()
              onFillOpacityChanged: requestPaint()
              onShowShadowChanged: requestPaint()

              onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var skew = 15
                if (showShadow) {
                  ctx.globalAlpha = 0.6
                  ctx.fillStyle = dropShadowColor
                  ctx.beginPath()
                  ctx.moveTo(skew + 3, 2 + 3)
                  ctx.lineTo(width + 3, 2 + 3)
                  ctx.lineTo(width - skew + 3, 18 + 3)
                  ctx.lineTo(0 + 3, 18 + 3)
                  ctx.closePath()
                  ctx.fill()
                }
                ctx.globalAlpha = fillOpacity
                ctx.fillStyle = fillColor
                ctx.beginPath()
                ctx.moveTo(skew, 2)
                ctx.lineTo(width, 2)
                ctx.lineTo(width - skew, 18)
                ctx.lineTo(0, 18)
                ctx.closePath()
                ctx.fill()
                ctx.globalAlpha = fillOpacity
                ctx.strokeStyle = borderColor
                ctx.lineWidth = 1.5
                ctx.stroke()
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (parent.isSelected) {
                  wallpaperSelector.selectedColorFilter = -1
                } else {
                  wallpaperSelector.selectedColorFilter = parent.filterValue
                }
              }
            }
          }
        }
      }


      Rectangle {
        width: 1; height: 20
        color: wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.primary.r, wallpaperSelector.colors.primary.g, wallpaperSelector.colors.primary.b, 0.3) : Qt.rgba(1, 1, 1, 0.2)
      }


      Row {
        spacing: 4
        anchors.verticalCenter: parent.verticalCenter

        Repeater {
          model: [
            { mode: "date", icon: "󰃰", label: "Newest" },
            { mode: "color", icon: "󰏘", label: "Color" }
          ]

          Rectangle {
            width: 32; height: 24; radius: 4
            property bool isSelected: wallpaperSelector.sortMode === modelData.mode
            property bool isHovered: sortMouseArea.containsMouse

            color: isSelected
              ? (wallpaperSelector.colors ? wallpaperSelector.colors.primary : "#4fc3f7")
              : (isHovered
                ? (wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.surfaceVariant.r, wallpaperSelector.colors.surfaceVariant.g, wallpaperSelector.colors.surfaceVariant.b, 0.5) : Qt.rgba(1, 1, 1, 0.15))
                : "transparent")

            border.width: isSelected ? 0 : 1
            border.color: isHovered ? (wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.primary.r, wallpaperSelector.colors.primary.g, wallpaperSelector.colors.primary.b, 0.4) : Qt.rgba(1, 1, 1, 0.2)) : "transparent"

            Behavior on color { ColorAnimation { duration: 100 } }
            Behavior on border.color { ColorAnimation { duration: 100 } }

            Text {
              anchors.centerIn: parent
              text: modelData.icon
              font.pixelSize: 14
              font.family: Style.fontFamilyNerdIcons
              color: parent.isSelected
                ? (wallpaperSelector.colors ? wallpaperSelector.colors.primaryText : "#000")
                : (wallpaperSelector.colors ? wallpaperSelector.colors.tertiary : "#8bceff")
            }

            MouseArea {
              id: sortMouseArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                wallpaperSelector.sortMode = modelData.mode
                wallpaperSelector.updateFilteredModel()
              }
            }

            ToolTip {
              visible: sortMouseArea.containsMouse
              text: modelData.label
              delay: 500
            }
          }
        }
      }


      Text {
        text: filteredModel.count + (filteredModel.count !== wallpaperModel.count ? "/" + wallpaperModel.count : "")
        font.family: Style.fontFamily
        font.pixelSize: 11
        font.weight: Font.Medium
        color: wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.surfaceText.r, wallpaperSelector.colors.surfaceText.g, wallpaperSelector.colors.surfaceText.b, 0.5) : Qt.rgba(1, 1, 1, 0.4)
        anchors.verticalCenter: parent.verticalCenter
      }
    }


    // Tag cloud panel (toggled with Shift+Down)
    Rectangle {
      id: tagCloudBg
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: 10
      anchors.bottomMargin: 8
      height: wallpaperSelector.tagCloudVisible ? wallpaperSelector.tagCloudHeight + 4 : 0
      visible: wallpaperSelector.tagCloudVisible
      radius: 16
      color: wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.surfaceContainer.r,
                                                 wallpaperSelector.colors.surfaceContainer.g,
                                                 wallpaperSelector.colors.surfaceContainer.b, 0.85)
                                      : Qt.rgba(0.1, 0.12, 0.18, 0.85)

      Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
    }


    Flickable {
      id: tagCloudFlickable
      anchors.fill: tagCloudBg
      anchors.margins: 8
      visible: wallpaperSelector.tagCloudVisible
      opacity: wallpaperSelector.tagCloudVisible ? 1.0 : 0.0
      clip: true
      contentWidth: width
      contentHeight: tagCloudRow.implicitHeight
      flickableDirection: Flickable.VerticalFlick
      boundsBehavior: Flickable.StopAtBounds

      Behavior on opacity { NumberAnimation { duration: 200 } }
      z: 11

      Rectangle {
        visible: tagCloudFlickable.contentHeight > tagCloudFlickable.height
        anchors.right: parent.right
        anchors.rightMargin: 2
        y: tagCloudFlickable.visibleArea.yPosition * tagCloudFlickable.height
        width: 4
        height: tagCloudFlickable.visibleArea.heightRatio * tagCloudFlickable.height
        radius: 2
        color: wallpaperSelector.colors ? wallpaperSelector.colors.primary : "#fff"
        opacity: 0.5
      }

      Flow {
        id: tagCloudRow
        width: parent.width - 10
        spacing: 8

        Repeater {
          model: wallpaperSelector.popularTags

          Rectangle {
            id: tagChip
            width: tagText.width + 16
            height: 26
            radius: 4
            property bool isSelected: wallpaperSelector.selectedTags.indexOf(modelData.tag) !== -1
            property bool isHovered: tagMouse.containsMouse

            color: isSelected
              ? (wallpaperSelector.colors ? wallpaperSelector.colors.primary : "#4fc3f7")
              : (isHovered
                ? (wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.surfaceVariant.r, wallpaperSelector.colors.surfaceVariant.g, wallpaperSelector.colors.surfaceVariant.b, 0.5) : "#444")
                : "transparent")

            border.width: isSelected ? 0 : 1
            border.color: isSelected ? "transparent" : (isHovered ? (wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.primary.r, wallpaperSelector.colors.primary.g, wallpaperSelector.colors.primary.b, 0.4) : Qt.rgba(1, 1, 1, 0.2)) : (wallpaperSelector.colors ? wallpaperSelector.colors.outline : Qt.rgba(1, 1, 1, 0.15)))

            Behavior on color { ColorAnimation { duration: 100 } }
            Behavior on border.color { ColorAnimation { duration: 100 } }

            Text {
              id: tagText
              anchors.centerIn: parent
              text: modelData.tag.toUpperCase()
              color: tagChip.isSelected
                ? (wallpaperSelector.colors ? wallpaperSelector.colors.primaryText : "#000")
                : (wallpaperSelector.colors ? wallpaperSelector.colors.tertiary : "#8bceff")
              font.family: Style.fontFamily
              font.pixelSize: 11
              font.weight: tagChip.isSelected ? Font.Bold : Font.Medium
              font.letterSpacing: 0.5
            }

            MouseArea {
              id: tagMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                var tags = wallpaperSelector.selectedTags.slice()
                var idx = tags.indexOf(modelData.tag)
                if (idx !== -1) {
                  tags.splice(idx, 1)
                } else {
                  tags.push(modelData.tag)
                }
                wallpaperSelector.selectedTags = tags
                wallpaperSelector.updateFilteredModel()
              }
            }
          }
        }
      }
    }


    // Right-click context menu (delete, view on Steam)
    Rectangle {
      id: contextMenu
      visible: wallpaperSelector.contextMenuVisible
      x: Math.min(wallpaperSelector.contextMenuX, parent.width - width - 10)
      y: Math.min(wallpaperSelector.contextMenuY, parent.height - height - 10)
      width: 220
      height: contextMenuColumn.height + 16
      radius: 12
      color: wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.surfaceContainer.r, wallpaperSelector.colors.surfaceContainer.g, wallpaperSelector.colors.surfaceContainer.b, 0.95) : "#2a2a2a"
      border.width: 1
      border.color: wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.primary.r, wallpaperSelector.colors.primary.g, wallpaperSelector.colors.primary.b, 0.3) : Qt.rgba(1, 1, 1, 0.15)
      z: 100

      MouseArea {
        anchors.fill: parent
      }

      Column {
        id: contextMenuColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 8
        spacing: 4

        Text {
          width: parent.width
          text: wallpaperSelector.contextMenuName.toUpperCase()
          color: wallpaperSelector.colors ? wallpaperSelector.colors.tertiary : "#8bceff"
          font.family: Style.fontFamily
          font.pixelSize: 13
          font.weight: Font.Bold
          font.letterSpacing: 0.5
          elide: Text.ElideMiddle
          horizontalAlignment: Text.AlignLeft
          leftPadding: 8
          topPadding: 4
          bottomPadding: 8
        }

        Rectangle {
          width: parent.width; height: 1
          color: Qt.rgba(1, 1, 1, 0.1)
        }


        Rectangle {
          width: parent.width; height: 36
          color: deleteHover.containsMouse ? Qt.rgba(wallpaperSelector.colors ? wallpaperSelector.colors.primary.r : 1, wallpaperSelector.colors ? wallpaperSelector.colors.primary.g : 0.3, wallpaperSelector.colors ? wallpaperSelector.colors.primary.b : 0.3, 0.2) : "transparent"
          border.width: deleteHover.containsMouse ? 1 : 0
          border.color: wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.primary.r, wallpaperSelector.colors.primary.g, wallpaperSelector.colors.primary.b, 0.4) : Qt.rgba(1, 1, 1, 0.2)
          Behavior on color { ColorAnimation { duration: 100 } }

          Row {
            anchors.fill: parent
            anchors.leftMargin: 8
            spacing: 10
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "🗑"; font.pixelSize: 14
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "DELETE LOCALLY"
              color: wallpaperSelector.colors ? wallpaperSelector.colors.tertiary : "#8bceff"
              font.family: Style.fontFamily
              font.pixelSize: 12
              font.weight: Font.Medium
              font.letterSpacing: 0.5
            }
          }

          MouseArea {
            id: deleteHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              deleteWallpaper.remove(
                wallpaperSelector.contextMenuType,
                wallpaperSelector.contextMenuName,
                wallpaperSelector.contextMenuWeId
              )
              wallpaperSelector.contextMenuVisible = false
            }
          }
        }


        Rectangle {
          visible: wallpaperSelector.contextMenuType === "we"
          width: parent.width; height: 36
          color: unsubHover.containsMouse ? Qt.rgba(wallpaperSelector.colors ? wallpaperSelector.colors.primary.r : 1, wallpaperSelector.colors ? wallpaperSelector.colors.primary.g : 0.5, wallpaperSelector.colors ? wallpaperSelector.colors.primary.b : 0, 0.2) : "transparent"
          border.width: unsubHover.containsMouse ? 1 : 0
          border.color: wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.primary.r, wallpaperSelector.colors.primary.g, wallpaperSelector.colors.primary.b, 0.4) : Qt.rgba(1, 1, 1, 0.2)
          Behavior on color { ColorAnimation { duration: 100 } }

          Row {
            anchors.fill: parent
            anchors.leftMargin: 8
            spacing: 10
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "☁"; font.pixelSize: 14
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "VIEW ON STEAM"
              color: wallpaperSelector.colors ? wallpaperSelector.colors.tertiary : "#8bceff"
              font.family: Style.fontFamily
              font.pixelSize: 12
              font.weight: Font.Medium
              font.letterSpacing: 0.5
            }
          }

          MouseArea {
            id: unsubHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              unsubscribeWE.unsubscribe(wallpaperSelector.contextMenuWeId)
              wallpaperSelector.contextMenuVisible = false
            }
          }
        }
      }
    }


    MouseArea {
      anchors.fill: parent
      visible: wallpaperSelector.contextMenuVisible
      z: 99
      onClicked: wallpaperSelector.contextMenuVisible = false
    }


    // Cache loading progress bar
    Rectangle {
      id: progressContainer
      anchors.bottom: parent.bottom
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottomMargin: 30
      width: 400
      height: 40
      radius: 20
      color: wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.surfaceContainer.r, wallpaperSelector.colors.surfaceContainer.g, wallpaperSelector.colors.surfaceContainer.b, 0.9) : Qt.rgba(0, 0, 0, 0.8)
      visible: wallpaperSelector.cacheLoading
      opacity: wallpaperSelector.cacheLoading ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 200 } }

      Rectangle {
        id: progressBg
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: 16
        height: 4
        radius: 2
        color: Qt.rgba(1, 1, 1, 0.1)

        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          radius: 2
          width: wallpaperSelector.cacheTotal > 0
            ? parent.width * (wallpaperSelector.cacheProgress / wallpaperSelector.cacheTotal)
            : 0
          color: wallpaperSelector.colors ? wallpaperSelector.colors.primary : "#4fc3f7"
          Behavior on width { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
        }
      }

      Text {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -12
        text: wallpaperSelector.cacheTotal > 0
          ? "LOADING WALLPAPERS... " + wallpaperSelector.cacheProgress + " / " + wallpaperSelector.cacheTotal
          : "SCANNING..."
        color: wallpaperSelector.colors ? wallpaperSelector.colors.tertiary : "#8bceff"
        font.family: Style.fontFamily
        font.pixelSize: 12
        font.weight: Font.Medium
        font.letterSpacing: 0.5
      }
    }
  }
  }


    // Horizontal parallelogram slice list view
    ListView {
      id: sliceListView

      anchors.top: cardContainer.top
      anchors.topMargin: wallpaperSelector.topBarHeight + 15
      anchors.bottom: cardContainer.bottom
      anchors.bottomMargin: (wallpaperSelector.tagCloudVisible ? wallpaperSelector.tagCloudHeight : 0) + 20

      anchors.horizontalCenter: parent.horizontalCenter
      property int visibleCount: 12
      width: wallpaperSelector.expandedWidth + (visibleCount - 1) * (wallpaperSelector.sliceWidth + wallpaperSelector.sliceSpacing)

      orientation: ListView.Horizontal
      model: filteredModel
      clip: false
      spacing: wallpaperSelector.sliceSpacing

      flickDeceleration: 1500
      maximumFlickVelocity: 3000
      boundsBehavior: Flickable.StopAtBounds
      cacheBuffer: wallpaperSelector.expandedWidth * 4

      visible: wallpaperSelector.cardVisible

      property bool keyboardNavActive: false
      property real lastMouseX: -1
      property real lastMouseY: -1

      highlightFollowsCurrentItem: true
      highlightMoveDuration: 350
      highlight: Item {}

      preferredHighlightBegin: (width - wallpaperSelector.expandedWidth) / 2
      preferredHighlightEnd: (width + wallpaperSelector.expandedWidth) / 2
      highlightRangeMode: ListView.StrictlyEnforceRange

      header: Item { width: (sliceListView.width - wallpaperSelector.expandedWidth) / 2; height: 1 }
      footer: Item { width: (sliceListView.width - wallpaperSelector.expandedWidth) / 2; height: 1 }

      focus: wallpaperSelector.showing
      onVisibleChanged: {
        if (visible) forceActiveFocus()
      }

      Connections {
        target: wallpaperSelector
        function onShowingChanged() {
          if (!wallpaperSelector.showing) {
            wallpaperSelector.lastContentX = sliceListView.contentX
            wallpaperSelector.lastIndex = sliceListView.currentIndex
          } else {
            sliceListView.forceActiveFocus()
          }
        }
      }
      onCountChanged: {
        if (count > 0 && wallpaperSelector.showing) {
          contentX = wallpaperSelector.lastContentX
          currentIndex = Math.min(wallpaperSelector.lastIndex, count - 1)
        }
      }

      MouseArea {
        anchors.fill: parent
        propagateComposedEvents: true
        onWheel: function(wheel) {

          var step = 1
          if (wheel.angleDelta.y > 0 || wheel.angleDelta.x > 0) {
            sliceListView.currentIndex = Math.max(0, sliceListView.currentIndex - step)
          } else if (wheel.angleDelta.y < 0 || wheel.angleDelta.x < 0) {
            sliceListView.currentIndex = Math.min(filteredModel.count - 1, sliceListView.currentIndex + step)
          }
        }
        onPressed: function(mouse) { mouse.accepted = false }
        onReleased: function(mouse) { mouse.accepted = false }
        onClicked: function(mouse) { mouse.accepted = false }
      }

      Timer {
        id: wheelDebounce
        interval: 400
        onTriggered: {
          var centerX = sliceListView.contentX + sliceListView.width / 2
          var nearest = sliceListView.indexAt(centerX, sliceListView.height / 2)
          if (nearest >= 0) sliceListView.currentIndex = nearest
        }
      }

      Keys.onEscapePressed: wallpaperSelector.showing = false
      Keys.onReturnPressed: {
        if (currentIndex >= 0 && currentIndex < filteredModel.count) {
          const item = filteredModel.get(currentIndex)
          if (item.type === "we") {
            applyWEWallpaper.apply(item.weId)
          } else if (item.type === "video") {
            applyVideoWallpaper.apply(item.path)
          } else {
            applyWallpaper.apply(item.path)
          }
        }
      }
      Keys.onPressed: function(event) {

        if (event.modifiers & Qt.ShiftModifier) {
          if (event.key === Qt.Key_Down) {
            wallpaperSelector.tagCloudVisible = !wallpaperSelector.tagCloudVisible
            if (!wallpaperSelector.tagCloudVisible) {
              wallpaperSelector.selectedTags = []
              wallpaperSelector.updateFilteredModel()
            }
            event.accepted = true
            return
          } else if (event.key === Qt.Key_Left) {
            if (wallpaperSelector.selectedColorFilter === -1) {
              wallpaperSelector.selectedColorFilter = 99
            } else if (wallpaperSelector.selectedColorFilter === 99) {
              wallpaperSelector.selectedColorFilter = 11
            } else if (wallpaperSelector.selectedColorFilter === 0) {
              wallpaperSelector.selectedColorFilter = 99
            } else {
              wallpaperSelector.selectedColorFilter--
            }
            event.accepted = true
            return
          } else if (event.key === Qt.Key_Right) {
            if (wallpaperSelector.selectedColorFilter === -1) {
              wallpaperSelector.selectedColorFilter = 0
            } else if (wallpaperSelector.selectedColorFilter === 11) {
              wallpaperSelector.selectedColorFilter = 99
            } else if (wallpaperSelector.selectedColorFilter === 99) {
              wallpaperSelector.selectedColorFilter = 0
            } else {
              wallpaperSelector.selectedColorFilter++
            }
            event.accepted = true
            return
          }
        }
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
          keyboardNavActive = true
        }

        if (event.key === Qt.Key_Left && !(event.modifiers & Qt.ShiftModifier)) {
          if (currentIndex > 0) {
            currentIndex--
          }
          event.accepted = true
          return
        }

        if (event.key === Qt.Key_Right && !(event.modifiers & Qt.ShiftModifier)) {
          if (currentIndex < filteredModel.count - 1) {
            currentIndex++
          }
          event.accepted = true
          return
        }
      }

      // Parallelogram slice delegate
      delegate: Item {
        id: delegateItem

        width: isCurrent ? wallpaperSelector.expandedWidth : wallpaperSelector.sliceWidth
        height: sliceListView.height
        property bool isCurrent: ListView.isCurrentItem
        property bool isHovered: itemMouseArea.containsMouse

        z: isCurrent ? 100 : (isHovered ? 90 : 50 - Math.min(Math.abs(index - sliceListView.currentIndex), 50))

        property real viewX: x - sliceListView.contentX
        property real fadeZone: wallpaperSelector.sliceWidth * 1.5
        property real edgeOpacity: {
          if (fadeZone <= 0) return 1.0
          var center = viewX + width * 0.5

          var leftFade = Math.min(1.0, Math.max(0.0, center / fadeZone))
          var rightFade = Math.min(1.0, Math.max(0.0, (sliceListView.width - center) / fadeZone))
          return Math.min(leftFade, rightFade)
        }
        opacity: edgeOpacity
        Behavior on width {
          NumberAnimation { duration: 200; easing.type: Easing.OutQuad }
        }


        containmentMask: Item {
          id: hitMask
          function contains(point) {
            var w = delegateItem.width
            var h = delegateItem.height
            var sk = wallpaperSelector.skewOffset
            if (h <= 0 || w <= 0) return false


            var leftX = sk * (1.0 - point.y / h)


            var rightX = w - sk * (point.y / h)
            return point.x >= leftX && point.x <= rightX && point.y >= 0 && point.y <= h
          }
        }

        Canvas {
          id: shadowCanvas
          z: -1
          anchors.fill: parent
          anchors.margins: -10
          property real shadowOffsetX: delegateItem.isCurrent ? 4 : 2
          property real shadowOffsetY: delegateItem.isCurrent ? 10 : 5
          property real shadowAlpha: delegateItem.isCurrent ? 0.6 : 0.4
          onWidthChanged: requestPaint()
          onHeightChanged: requestPaint()
          onShadowAlphaChanged: requestPaint()
          onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            var ox = 10
            var oy = 10
            var w = delegateItem.width
            var h = delegateItem.height
            var sk = wallpaperSelector.skewOffset
            var sx = shadowOffsetX
            var sy = shadowOffsetY
            var layers = [
              { dx: sx, dy: sy, alpha: shadowAlpha * 0.5 },
              { dx: sx * 0.6, dy: sy * 0.6, alpha: shadowAlpha * 0.3 },
              { dx: sx * 1.4, dy: sy * 1.4, alpha: shadowAlpha * 0.2 }
            ]
            for (var i = 0; i < layers.length; i++) {
              var l = layers[i]
              ctx.globalAlpha = l.alpha
              ctx.fillStyle = "#000000"
              ctx.beginPath()
              ctx.moveTo(ox + sk + l.dx, oy + l.dy)
              ctx.lineTo(ox + w + l.dx, oy + l.dy)
              ctx.lineTo(ox + w - sk + l.dx, oy + h + l.dy)
              ctx.lineTo(ox + l.dx, oy + h + l.dy)
              ctx.closePath()
              ctx.fill()
            }
          }
        }

        Item {
          id: imageContainer
          anchors.fill: parent
          Image {
            id: thumbImage
            anchors.fill: parent
            source: "file://" + model.thumb
            fillMode: Image.PreserveAspectCrop
            smooth: true
            asynchronous: true
            sourceSize.width: wallpaperSelector.expandedWidth
            sourceSize.height: wallpaperSelector.sliceHeight
          }

          Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, delegateItem.isCurrent ? 0 : (delegateItem.isHovered ? 0.15 : 0.4))
            Behavior on color { ColorAnimation { duration: 200 } }
          }
          layer.enabled: true
          layer.smooth: true
          layer.samples: 4
          layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: ShaderEffectSource {
              sourceItem: Item {
                width: imageContainer.width
                height: imageContainer.height
                layer.enabled: true
                layer.smooth: true
                layer.samples: 8
                Shape {
                  anchors.fill: parent
                  antialiasing: true
                  preferredRendererType: Shape.CurveRenderer
                  ShapePath {
                    fillColor: "white"
                    strokeColor: "transparent"
                    startX: wallpaperSelector.skewOffset
                    startY: 0
                    PathLine { x: delegateItem.width; y: 0 }
                    PathLine { x: delegateItem.width - wallpaperSelector.skewOffset; y: delegateItem.height }
                    PathLine { x: 0; y: delegateItem.height }
                    PathLine { x: wallpaperSelector.skewOffset; y: 0 }
                  }
                }
              }
            }
            maskThresholdMin: 0.3
            maskSpreadAtMin: 0.3
          }
        }

        // Video preview (plays after 300ms hover on current)
        property string videoPath: model.videoFile ? model.videoFile : ""
        property bool hasVideo: videoPath.length > 0
        property bool videoActive: false

        onIsCurrentChanged: {
          if (isCurrent && hasVideo) {
            videoDelayTimer.restart()
          } else {
            videoDelayTimer.stop()
            videoActive = false
          }
        }

        Timer {
          id: videoDelayTimer
          interval: 300
          onTriggered: delegateItem.videoActive = true
        }

        Loader {
          id: videoLoader
          anchors.fill: parent
          active: delegateItem.videoActive
          property bool isPlaying: active && status === Loader.Ready

          sourceComponent: Item {
            anchors.fill: parent

            Video {
              id: videoElement
              anchors.fill: parent
              source: "file://" + delegateItem.videoPath
              fillMode: VideoOutput.PreserveAspectCrop
              loops: MediaPlayer.Infinite
              muted: true
              Component.onCompleted: play()
            }

            layer.enabled: true
            layer.smooth: true
            layer.samples: 4
            layer.effect: MultiEffect {
              maskEnabled: true
              maskSource: ShaderEffectSource {
                sourceItem: Item {
                  width: delegateItem.width
                  height: delegateItem.height
                  layer.enabled: true
                  layer.smooth: true
                  Shape {
                    anchors.fill: parent
                    antialiasing: true
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                      fillColor: "white"
                      strokeColor: "transparent"
                      startX: wallpaperSelector.skewOffset
                      startY: 0
                      PathLine { x: delegateItem.width; y: 0 }
                      PathLine { x: delegateItem.width - wallpaperSelector.skewOffset; y: delegateItem.height }
                      PathLine { x: 0; y: delegateItem.height }
                      PathLine { x: wallpaperSelector.skewOffset; y: 0 }
                    }
                  }
                }
              }
              maskThresholdMin: 0.3
              maskSpreadAtMin: 0.3
            }
          }
        }

        Shape {
          id: glowBorder
          anchors.fill: parent
          antialiasing: true
          preferredRendererType: Shape.CurveRenderer
          opacity: 1.0
          ShapePath {
            fillColor: "transparent"
            strokeColor: delegateItem.isCurrent
              ? (wallpaperSelector.colors ? wallpaperSelector.colors.primary : "#8BC34A")
              : (delegateItem.isHovered
                ? Qt.rgba(wallpaperSelector.colors ? wallpaperSelector.colors.primary.r : 0.5, wallpaperSelector.colors ? wallpaperSelector.colors.primary.g : 0.76, wallpaperSelector.colors ? wallpaperSelector.colors.primary.b : 0.29, 0.4)
                : Qt.rgba(0, 0, 0, 0.6))
            Behavior on strokeColor { ColorAnimation { duration: 200 } }
            strokeWidth: delegateItem.isCurrent ? 3 : 1
            startX: wallpaperSelector.skewOffset
            startY: 0
            PathLine { x: delegateItem.width; y: 0 }
            PathLine { x: delegateItem.width - wallpaperSelector.skewOffset; y: delegateItem.height }
            PathLine { x: 0; y: delegateItem.height }
            PathLine { x: wallpaperSelector.skewOffset; y: 0 }
          }
        }

        Rectangle {
          id: videoIndicator
          anchors.top: parent.top
          anchors.topMargin: 10
          anchors.right: parent.right
          anchors.rightMargin: 10
          width: 22
          height: 22
          radius: 11
          color: delegateItem.videoActive ? (wallpaperSelector.colors ? wallpaperSelector.colors.primary : "#4fc3f7") : Qt.rgba(0, 0, 0, 0.7)
          border.width: 1
          border.color: delegateItem.videoActive
            ? "transparent"
            : (wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.primary.r, wallpaperSelector.colors.primary.g, wallpaperSelector.colors.primary.b, 0.6) : Qt.rgba(1, 1, 1, 0.4))
          visible: delegateItem.hasVideo
          z: 10

          Behavior on color { ColorAnimation { duration: 200 } }

          Text {
            anchors.centerIn: parent
            anchors.horizontalCenterOffset: 1
            text: "▶"
            font.pixelSize: 9
            color: delegateItem.videoActive
              ? (wallpaperSelector.colors ? wallpaperSelector.colors.primaryText : "#000")
              : (wallpaperSelector.colors ? wallpaperSelector.colors.primary : "#4fc3f7")
          }
        }

        Rectangle {
          id: nameLabel
          anchors.bottom: parent.bottom
          anchors.bottomMargin: 40
          anchors.horizontalCenter: parent.horizontalCenter
          width: nameText.width + 24
          height: 32
          radius: 6
          color: Qt.rgba(0, 0, 0, 0.75)
          border.width: 1
          border.color: wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.primary.r, wallpaperSelector.colors.primary.g, wallpaperSelector.colors.primary.b, 0.5) : Qt.rgba(1, 1, 1, 0.2)
          visible: delegateItem.isCurrent
          opacity: delegateItem.isCurrent ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 200 } }
          Text {
            id: nameText
            anchors.centerIn: parent
            text: model.name.replace(/\.[^/.]+$/, "").toUpperCase()
            font.family: Style.fontFamily
            font.pixelSize: 12
            font.weight: Font.Bold
            font.letterSpacing: 0.5
            color: wallpaperSelector.colors ? wallpaperSelector.colors.tertiary : "#8bceff"
            elide: Text.ElideMiddle
            maximumLineCount: 1
            width: Math.min(implicitWidth, delegateItem.width - 60)
          }
        }

        Rectangle {
          anchors.bottom: parent.bottom
          anchors.bottomMargin: 8
          anchors.right: parent.right
          anchors.rightMargin: wallpaperSelector.skewOffset + 8
          width: typeBadgeText.width + 8
          height: 16
          radius: 4
          color: Qt.rgba(0, 0, 0, 0.75)
          border.width: 1
          border.color: wallpaperSelector.colors ? Qt.rgba(wallpaperSelector.colors.primary.r, wallpaperSelector.colors.primary.g, wallpaperSelector.colors.primary.b, 0.4) : Qt.rgba(1, 1, 1, 0.2)
          z: 10

          Text {
            id: typeBadgeText
            anchors.centerIn: parent
            text: model.type === "static" ? "PIC" : (model.type === "video" ? "VID" : "WE")
            font.family: Style.fontFamily
            font.pixelSize: 9
            font.weight: Font.Bold
            font.letterSpacing: 0.5
            color: wallpaperSelector.colors ? wallpaperSelector.colors.tertiary : "#8bceff"
          }
        }

        // Matugen color preview dots (bottom-left of selected slice)
        Row {
          anchors.bottom: parent.bottom
          anchors.bottomMargin: 12
          anchors.left: parent.left
          anchors.leftMargin: wallpaperSelector.skewOffset + 8
          spacing: 6
          visible: delegateItem.isCurrent && wallpaperColors !== undefined
          property var wallpaperColors: {
            var key = model.weId ? model.weId : model.name.replace(/\.[^/.]+$/, "")
            return wallpaperSelector.matugenDb[key]
          }
          Rectangle {
            width: 14; height: 14; radius: 7
            color: parent.wallpaperColors ? parent.wallpaperColors.primary : "#888"
            border.width: 1; border.color: Qt.rgba(0, 0, 0, 0.5)
            visible: parent.wallpaperColors !== undefined
          }
          Rectangle {
            width: 14; height: 14; radius: 7
            color: parent.wallpaperColors ? parent.wallpaperColors.secondary : "#666"
            border.width: 1; border.color: Qt.rgba(0, 0, 0, 0.5)
            visible: parent.wallpaperColors !== undefined
          }
          Rectangle {
            width: 14; height: 14; radius: 7
            color: parent.wallpaperColors ? parent.wallpaperColors.tertiary : "#444"
            border.width: 1; border.color: Qt.rgba(0, 0, 0, 0.5)
            visible: parent.wallpaperColors !== undefined
          }
        }

        // Mouse interaction (hover, click to apply, right-click context menu)
        MouseArea {
          id: itemMouseArea
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          cursorShape: Qt.PointingHandCursor
          onPositionChanged: function(mouse) {
            var globalPos = mapToItem(sliceListView, mouse.x, mouse.y)
            var dx = Math.abs(globalPos.x - sliceListView.lastMouseX)
            var dy = Math.abs(globalPos.y - sliceListView.lastMouseY)
            if (dx > 2 || dy > 2) {
              sliceListView.lastMouseX = globalPos.x
              sliceListView.lastMouseY = globalPos.y
              sliceListView.keyboardNavActive = false
              sliceListView.currentIndex = index
            }
          }
          onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton) {
              var pos = mapToItem(backgroundRect, mouse.x, mouse.y)
              wallpaperSelector.contextMenuName = model.name
              wallpaperSelector.contextMenuType = model.type
              wallpaperSelector.contextMenuWeId = model.weId || ""
              wallpaperSelector.contextMenuPath = model.path || ""
              wallpaperSelector.contextMenuX = pos.x
              wallpaperSelector.contextMenuY = pos.y
              wallpaperSelector.contextMenuVisible = true
            } else {

              if (delegateItem.isCurrent) {
                if (model.type === "we") {
                  applyWEWallpaper.apply(model.weId)
                } else if (model.type === "video") {
                  applyVideoWallpaper.apply(model.path)
                } else {
                  applyWallpaper.apply(model.path)
                }
              } else {
                sliceListView.currentIndex = index
              }
            }
          }
        }
    }
    }

  }
}
