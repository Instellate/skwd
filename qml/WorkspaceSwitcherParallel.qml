// Imports
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import QtQuick.Controls
import QtQuick.Shapes
import "components"


Scope {
  id: workspaceSwitcher

  // State properties
  property var colors
  property bool showing: false

  property string mainMonitor: Config.mainMonitor

  signal workspaceSwitched()

  // Show/hide lifecycle and data fetching trigger
  onShowingChanged: {
    if (showing) {
      screenshotCounter++
      grimCapture.command = ["sh", "-c", buildGrimCommand()]
      grimCapture.running = true
      fetchWorkspaces.buf = ""
      fetchWorkspaces.running = true
      fetchWindows.buf = ""
      fetchWindows.running = true
      cardShowTimer.restart()
    } else {
      cardVisible = false
    }
  }

  // Delayed card visibility and focus timers
  Timer {
    id: cardShowTimer
    interval: 50
    onTriggered: workspaceSwitcher.cardVisible = true
  }

  Timer {
    id: focusTimer
    interval: 50
    onTriggered: sliceListView.forceActiveFocus()
  }


  // Parallelogram slice dimensions
  property int sliceWidth: 135
  property int expandedWidth: 924
  property int sliceHeight: 520
  property int skewOffset: 35
  property int sliceSpacing: -22

  property string homeDir: Config.homeDir
  property string thumbDir: homeDir + "/.cache/workspace-thumbs"


  // Card container dimensions
  property int cardWidth: 1600
  property int topBarHeight: 50
  property int cardHeight: sliceHeight + topBarHeight + 60

  property bool cardVisible: false


  property string monitorFilter: ""


  property int screenshotCounter: 0


  // Workspace and window data state
  property bool wsReady: false
  property bool winReady: false
  property var wsData: []
  property var winData: []

  // Build workspace model from fetched data
  function tryBuild() {
    if (!wsReady || !winReady) return
    workspaceModel.clear()
    var wsList = wsData.slice()
    wsList.sort(function(a, b) {
      if (a.output < b.output) return -1
      if (a.output > b.output) return 1
      return a.idx - b.idx
    })
    for (var i = 0; i < wsList.length; i++) {
      var ws = wsList[i]
      var wins = []
      for (var j = 0; j < winData.length; j++) {
        if (winData[j].workspace_id === ws.id) {
          wins.push({
            id: winData[j].id,
            title: winData[j].title || "",
            app_id: winData[j].app_id || "",
            is_focused: winData[j].is_focused || false
          })
        }
      }
      workspaceModel.append({
        wsId: ws.id || 0,
        wsIdx: ws.idx || 0,
        wsName: ws.name || "",
        output: ws.output || "",
        isActive: ws.is_active || false,
        isFocused: ws.is_focused || false,
        thumb: thumbDir + "/" + (ws.output || "") + ".png",
        windowCount: wins.length,
        windowsJson: JSON.stringify(wins)
      })
    }
    updateFilteredModel()
    wsReady = false
    winReady = false
  }


  // Scroll position persistence
  property int lastContentX: 0
  property int lastIndex: 0

  function resetScroll() {
    workspaceSwitcher.lastContentX = 0
    workspaceSwitcher.lastIndex = 0
    sliceListView.currentIndex = 0
    if (filteredModel.count > 0)
      sliceListView.positionViewAtIndex(0, ListView.Beginning)
  }


  // Data models and monitor filter logic
  ListModel { id: workspaceModel }
  ListModel { id: filteredModel }

  function updateFilteredModel() {
    filteredModel.clear()
    var mf = monitorFilter
    for (var i = 0; i < workspaceModel.count; i++) {
      var item = workspaceModel.get(i)
      if (mf !== "" && item.output !== mf) continue
      filteredModel.append({
        wsId: item.wsId,
        wsIdx: item.wsIdx,
        wsName: item.wsName,
        output: item.output,
        isActive: item.isActive,
        isFocused: item.isFocused,
        thumb: item.thumb,
        windowCount: item.windowCount,
        windowsJson: item.windowsJson
      })
    }

    var focusIdx = 0
    for (var j = 0; j < filteredModel.count; j++) {
      if (filteredModel.get(j).isFocused) { focusIdx = j; break }
      if (filteredModel.get(j).isActive && focusIdx === 0) focusIdx = j
    }
    if (filteredModel.count > 0) {
      sliceListView.currentIndex = focusIdx
    }
  }

  onMonitorFilterChanged: updateFilteredModel()


  // Build grim screenshot command for all monitors
  function buildGrimCommand() {
    var cmds = []
    for (var i = 0; i < Quickshell.screens.length; i++) {
      var name = Quickshell.screens[i].name
      cmds.push("grim -o " + name + " " + thumbDir + "/" + name + ".png 2>/dev/null")
    }
    return "mkdir -p " + thumbDir + "; " + cmds.join(" & ") + " & wait"
  }

  Process {
    id: grimCapture
    command: ["sh", "-c", "true"]
    running: false
  }


  // Fetch workspace list from compositor
  Process {
    id: fetchWorkspaces
    command: [Config.scriptsDir + "/bash/wm-action", "list-workspaces"]
    running: false
    property string buf: ""
    stdout: SplitParser {
      splitMarker: ""
      onRead: data => { fetchWorkspaces.buf += data }
    }
    onExited: {
      try { workspaceSwitcher.wsData = JSON.parse(fetchWorkspaces.buf) }
      catch (e) { workspaceSwitcher.wsData = [] }
      workspaceSwitcher.wsReady = true
      workspaceSwitcher.tryBuild()
    }
  }

  // Fetch window list from compositor
  Process {
    id: fetchWindows
    command: [Config.scriptsDir + "/bash/wm-action", "list-windows"]
    running: false
    property string buf: ""
    stdout: SplitParser {
      splitMarker: ""
      onRead: data => { fetchWindows.buf += data }
    }
    onExited: {
      try { workspaceSwitcher.winData = JSON.parse(fetchWindows.buf) }
      catch (e) { workspaceSwitcher.winData = [] }
      workspaceSwitcher.winReady = true
      workspaceSwitcher.tryBuild()
    }
  }


  // Workspace switching via wm-action
  Process {
    id: wsSwitchProcess
    command: ["true"]
  }

  function switchToWorkspace(wsIdx, output) {

    wsSwitchProcess.command = ["sh", "-c",
      Config.scriptsDir + "/bash/wm-action focus-monitor " + output + " && " + Config.scriptsDir + "/bash/wm-action focus-workspace " + wsIdx
    ]
    wsSwitchProcess.running = true
    workspaceSwitcher.showing = false
    workspaceSwitcher.workspaceSwitched()
  }


  // Full-screen overlay panel
  PanelWindow {
    id: switcherPanel

    screen: Quickshell.screens.find(s => s.name === workspaceSwitcher.mainMonitor) ?? Quickshell.screens[0]

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

    visible: workspaceSwitcher.showing
    color: "transparent"

    WlrLayershell.namespace: "workspace-switcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: workspaceSwitcher.showing ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    exclusionMode: ExclusionMode.Ignore

    // Background dim overlay
    DimOverlay {
      active: workspaceSwitcher.cardVisible
      dimOpacity: 0.5
      onClicked: workspaceSwitcher.showing = false
    }


    // Card container with fade-in animation
    Item {
      id: cardContainer
      width: workspaceSwitcher.cardWidth
      height: workspaceSwitcher.cardHeight
      anchors.centerIn: parent
      visible: workspaceSwitcher.cardVisible

      opacity: 0
      property bool animateIn: workspaceSwitcher.cardVisible

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


      Item {
        id: backgroundRect
        anchors.fill: parent


        // Monitor filter bar
        Rectangle {
          id: filterBarBg
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.top
          anchors.topMargin: 10
          width: topFilterBar.width + 30
          height: topFilterBar.height + 14
          radius: height / 2
          color: workspaceSwitcher.colors ? Qt.rgba(workspaceSwitcher.colors.surfaceContainer.r,
                                                     workspaceSwitcher.colors.surfaceContainer.g,
                                                     workspaceSwitcher.colors.surfaceContainer.b, 0.85)
                                          : Qt.rgba(0.1, 0.12, 0.18, 0.85)
          z: 10
        }

        Row {
          id: topFilterBar
          anchors.centerIn: filterBarBg
          spacing: 16
          z: 11


          // Monitor filter buttons (all + per-output)
          Row {
            id: monitorFilterRow
            spacing: 4
            anchors.verticalCenter: parent.verticalCenter


            Rectangle {
              width: 32
              height: 24
              radius: 4
              property bool isSelected: workspaceSwitcher.monitorFilter === ""
              property bool isHovered: allMonMouseArea.containsMouse
              color: isSelected
                ? (workspaceSwitcher.colors ? workspaceSwitcher.colors.primary : "#4fc3f7")
                : (isHovered
                  ? (workspaceSwitcher.colors ? Qt.rgba(workspaceSwitcher.colors.surfaceVariant.r, workspaceSwitcher.colors.surfaceVariant.g, workspaceSwitcher.colors.surfaceVariant.b, 0.5) : Qt.rgba(1, 1, 1, 0.15))
                  : "transparent")
              border.width: isSelected ? 0 : 1
              border.color: isHovered ? (workspaceSwitcher.colors ? Qt.rgba(workspaceSwitcher.colors.primary.r, workspaceSwitcher.colors.primary.g, workspaceSwitcher.colors.primary.b, 0.4) : Qt.rgba(1, 1, 1, 0.2)) : "transparent"
              Behavior on color { ColorAnimation { duration: 100 } }

              Text {
                anchors.centerIn: parent
                text: "󰄶"
                font.pixelSize: 14
                font.family: Style.fontFamilyIcons
                color: parent.isSelected
                  ? (workspaceSwitcher.colors ? workspaceSwitcher.colors.primaryText : "#000")
                  : (workspaceSwitcher.colors ? workspaceSwitcher.colors.tertiary : "#8bceff")
              }

              MouseArea {
                id: allMonMouseArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: workspaceSwitcher.monitorFilter = ""
              }

              ToolTip {
                visible: allMonMouseArea.containsMouse
                text: "All Monitors"
                delay: 500
              }
            }


            // Per-monitor filter buttons from available outputs
            Repeater {
              model: {
                var outputs = []
                var seen = {}
                for (var i = 0; i < workspaceModel.count; i++) {
                  var o = workspaceModel.get(i).output
                  if (!seen[o]) {
                    seen[o] = true
                    outputs.push(o)
                  }
                }
                return outputs
              }

              Rectangle {
                width: monLabel.width + 16
                height: 24
                radius: 4
                property bool isSelected: workspaceSwitcher.monitorFilter === modelData
                property bool isHovered: monMouseArea.containsMouse
                color: isSelected
                  ? (workspaceSwitcher.colors ? workspaceSwitcher.colors.primary : "#4fc3f7")
                  : (isHovered
                    ? (workspaceSwitcher.colors ? Qt.rgba(workspaceSwitcher.colors.surfaceVariant.r, workspaceSwitcher.colors.surfaceVariant.g, workspaceSwitcher.colors.surfaceVariant.b, 0.5) : Qt.rgba(1, 1, 1, 0.15))
                    : "transparent")
                border.width: isSelected ? 0 : 1
                border.color: isHovered ? (workspaceSwitcher.colors ? Qt.rgba(workspaceSwitcher.colors.primary.r, workspaceSwitcher.colors.primary.g, workspaceSwitcher.colors.primary.b, 0.4) : Qt.rgba(1, 1, 1, 0.2)) : "transparent"
                Behavior on color { ColorAnimation { duration: 100 } }

                Text {
                  id: monLabel
                  anchors.centerIn: parent
                  text: modelData
                  font.pixelSize: 11
                  font.family: Style.fontFamily
                  font.weight: Font.Bold
                  color: parent.isSelected
                    ? (workspaceSwitcher.colors ? workspaceSwitcher.colors.primaryText : "#000")
                    : (workspaceSwitcher.colors ? workspaceSwitcher.colors.tertiary : "#8bceff")
                }

                MouseArea {
                  id: monMouseArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    if (parent.isSelected) {
                      workspaceSwitcher.monitorFilter = ""
                    } else {
                      workspaceSwitcher.monitorFilter = modelData
                    }
                  }
                }
              }
            }
          }


          Rectangle {
            width: 1; height: 20
            color: workspaceSwitcher.colors ? Qt.rgba(workspaceSwitcher.colors.primary.r, workspaceSwitcher.colors.primary.g, workspaceSwitcher.colors.primary.b, 0.3) : Qt.rgba(1, 1, 1, 0.2)
            anchors.verticalCenter: parent.verticalCenter
          }


          Text {
            text: filteredModel.count + " workspaces"
            font.family: Style.fontFamily
            font.pixelSize: 11
            font.weight: Font.Medium
            color: workspaceSwitcher.colors ? Qt.rgba(workspaceSwitcher.colors.primaryText.r, workspaceSwitcher.colors.primaryText.g, workspaceSwitcher.colors.primaryText.b, 0.5) : Qt.rgba(1, 1, 1, 0.5)
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }
    }


    // Workspace card list (horizontal parallelogram slices)
    ListView {
      id: sliceListView
      anchors.top: cardContainer.top
      anchors.topMargin: workspaceSwitcher.topBarHeight + 15
      anchors.bottom: cardContainer.bottom
      anchors.bottomMargin: 20
      anchors.horizontalCenter: parent.horizontalCenter
      property int visibleCount: 12
      width: workspaceSwitcher.expandedWidth + (visibleCount - 1) * (workspaceSwitcher.sliceWidth + workspaceSwitcher.sliceSpacing)

      orientation: ListView.Horizontal
      model: filteredModel
      clip: false
      spacing: workspaceSwitcher.sliceSpacing

      flickDeceleration: 1500
      maximumFlickVelocity: 3000
      boundsBehavior: Flickable.StopAtBounds
      cacheBuffer: workspaceSwitcher.expandedWidth * 4

      visible: workspaceSwitcher.cardVisible

      property bool keyboardNavActive: false
      property real lastMouseX: -1
      property real lastMouseY: -1

      highlightFollowsCurrentItem: true
      highlightMoveDuration: 350
      highlight: Item {}
      preferredHighlightBegin: (width - workspaceSwitcher.expandedWidth) / 2
      preferredHighlightEnd: (width + workspaceSwitcher.expandedWidth) / 2
      highlightRangeMode: ListView.StrictlyEnforceRange
      header: Item { width: (sliceListView.width - workspaceSwitcher.expandedWidth) / 2; height: 1 }
      footer: Item { width: (sliceListView.width - workspaceSwitcher.expandedWidth) / 2; height: 1 }

      focus: workspaceSwitcher.showing
      onVisibleChanged: {
        if (visible) forceActiveFocus()
      }

      Connections {
        target: workspaceSwitcher
        function onShowingChanged() {
          if (workspaceSwitcher.showing) {
            sliceListView.forceActiveFocus()
          }
        }
      }


      // Scroll wheel navigation
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

      // Keyboard navigation (arrows, escape, enter, number keys)
      Keys.onEscapePressed: workspaceSwitcher.showing = false
      Keys.onReturnPressed: {
        if (currentIndex >= 0 && currentIndex < filteredModel.count) {
          var ws = filteredModel.get(currentIndex)
          workspaceSwitcher.switchToWorkspace(ws.wsIdx, ws.output)
        }
      }

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
          keyboardNavActive = true
        }
        if (event.key === Qt.Key_Left) {
          if (currentIndex > 0) currentIndex--
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Right) {
          if (currentIndex < filteredModel.count - 1) currentIndex++
          event.accepted = true
          return
        }

        var num = -1
        if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
          num = event.key - Qt.Key_1
        }
        if (num >= 0 && num < filteredModel.count) {
          var ws = filteredModel.get(num)
          workspaceSwitcher.switchToWorkspace(ws.wsIdx, ws.output)
          event.accepted = true
        }
      }


      // Workspace card delegate (parallelogram slice)
      delegate: Item {
        id: delegateItem
        width: isCurrent ? workspaceSwitcher.expandedWidth : workspaceSwitcher.sliceWidth
        height: sliceListView.height
        property bool isCurrent: ListView.isCurrentItem
        property bool isHovered: itemMouseArea.containsMouse
        z: isCurrent ? 100 : (isHovered ? 90 : 50 - Math.min(Math.abs(index - sliceListView.currentIndex), 50))
        property real viewX: x - sliceListView.contentX
        property real fadeZone: workspaceSwitcher.sliceWidth * 1.5
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


        // Parse window list for this workspace
        property var windowsList: {
          try { return JSON.parse(model.windowsJson) }
          catch (e) { return [] }
        }


        // Parallelogram hit-testing mask
        containmentMask: Item {
          id: hitMask
          function contains(point) {
            var w = delegateItem.width
            var h = delegateItem.height
            var sk = workspaceSwitcher.skewOffset
            if (h <= 0 || w <= 0) return false
            var leftX = sk * (1.0 - point.y / h)
            var rightX = w - sk * (point.y / h)
            return point.x >= leftX && point.x <= rightX && point.y >= 0 && point.y <= h
          }
        }


        // Multi-layer drop shadow
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
            var ox = 10; var oy = 10
            var w = delegateItem.width
            var h = delegateItem.height
            var sk = workspaceSwitcher.skewOffset
            var sx = shadowOffsetX; var sy = shadowOffsetY
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


        // Screenshot thumbnail and content layers
        Item {
          id: imageContainer
          anchors.fill: parent


          // Fallback gradient background
          Rectangle {
            anchors.fill: parent
            gradient: Gradient {
              GradientStop { position: 0.0; color: workspaceSwitcher.colors ? Qt.rgba(workspaceSwitcher.colors.surfaceContainer.r, workspaceSwitcher.colors.surfaceContainer.g, workspaceSwitcher.colors.surfaceContainer.b, 1) : "#1a1c2e" }
              GradientStop { position: 1.0; color: workspaceSwitcher.colors ? Qt.rgba(workspaceSwitcher.colors.surface.r, workspaceSwitcher.colors.surface.g, workspaceSwitcher.colors.surface.b, 1) : "#0e1018" }
            }
          }


          // Workspace screenshot thumbnail
          Image {
            id: thumbImage
            anchors.fill: parent
            source: model.thumb ? "file://" + model.thumb + "?v=" + workspaceSwitcher.screenshotCounter : ""
            fillMode: Image.PreserveAspectCrop
            smooth: true
            asynchronous: true
            cache: false
            sourceSize.width: workspaceSwitcher.expandedWidth
            sourceSize.height: workspaceSwitcher.sliceHeight
            visible: model.thumb !== ""
          }


          // Empty workspace placeholder
          Column {
            anchors.centerIn: parent
            spacing: 8
            visible: model.windowCount === 0
            opacity: 0.5
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "󰍹"
              font.family: Style.fontFamilyIcons
              font.pixelSize: 48
              color: workspaceSwitcher.colors ? workspaceSwitcher.colors.tertiary : "#8bceff"
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "EMPTY"
              font.family: Style.fontFamily
              font.pixelSize: 11
              font.weight: Font.Bold
              font.letterSpacing: 1
              color: workspaceSwitcher.colors ? workspaceSwitcher.colors.tertiary : "#8bceff"
            }
          }


          // Inactive slice darkening overlay
          Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, delegateItem.isCurrent ? 0 : (delegateItem.isHovered ? 0.15 : 0.4))
            Behavior on color { ColorAnimation { duration: 200 } }
          }

          // Parallelogram shape clipping mask
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
                    startX: workspaceSwitcher.skewOffset
                    startY: 0
                    PathLine { x: delegateItem.width; y: 0 }
                    PathLine { x: delegateItem.width - workspaceSwitcher.skewOffset; y: delegateItem.height }
                    PathLine { x: 0; y: delegateItem.height }
                    PathLine { x: workspaceSwitcher.skewOffset; y: 0 }
                  }
                }
              }
            }
            maskThresholdMin: 0.3
            maskSpreadAtMin: 0.3
          }
        }


        // Selection and hover border glow
        Shape {
          id: glowBorder
          anchors.fill: parent
          antialiasing: true
          preferredRendererType: Shape.CurveRenderer
          opacity: 1.0
          ShapePath {
            fillColor: "transparent"
            strokeColor: delegateItem.isCurrent
              ? (workspaceSwitcher.colors ? workspaceSwitcher.colors.primary : "#8BC34A")
              : (delegateItem.isHovered
                ? Qt.rgba(workspaceSwitcher.colors ? workspaceSwitcher.colors.primary.r : 0.5, workspaceSwitcher.colors ? workspaceSwitcher.colors.primary.g : 0.76, workspaceSwitcher.colors ? workspaceSwitcher.colors.primary.b : 0.29, 0.4)
                : Qt.rgba(0, 0, 0, 0.6))
            Behavior on strokeColor { ColorAnimation { duration: 200 } }
            strokeWidth: delegateItem.isCurrent ? 3 : 1
            startX: workspaceSwitcher.skewOffset
            startY: 0
            PathLine { x: delegateItem.width; y: 0 }
            PathLine { x: delegateItem.width - workspaceSwitcher.skewOffset; y: delegateItem.height }
            PathLine { x: 0; y: delegateItem.height }
            PathLine { x: workspaceSwitcher.skewOffset; y: 0 }
          }
        }


        // Active/focused workspace badge
        Rectangle {
          anchors.top: parent.top
          anchors.topMargin: 10
          anchors.left: parent.left
          anchors.leftMargin: workspaceSwitcher.skewOffset + 6
          width: activeLabel.width + 12
          height: 20
          radius: 10
          color: model.isActive
            ? (workspaceSwitcher.colors ? workspaceSwitcher.colors.primary : "#4fc3f7")
            : "transparent"
          border.width: model.isActive ? 0 : 1
          border.color: Qt.rgba(1, 1, 1, 0.3)
          visible: model.isActive
          z: 10

          Text {
            id: activeLabel
            anchors.centerIn: parent
            text: model.isFocused ? "FOCUSED" : "ACTIVE"
            font.family: Style.fontFamily
            font.pixelSize: 9
            font.weight: Font.Bold
            font.letterSpacing: 0.5
            color: model.isActive
              ? (workspaceSwitcher.colors ? workspaceSwitcher.colors.primaryText : "#000")
              : "#fff"
          }
        }


        // Workspace name and output label
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
          border.color: workspaceSwitcher.colors ? Qt.rgba(workspaceSwitcher.colors.primary.r, workspaceSwitcher.colors.primary.g, workspaceSwitcher.colors.primary.b, 0.5) : Qt.rgba(1, 1, 1, 0.2)
          visible: delegateItem.isCurrent
          opacity: delegateItem.isCurrent ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 200 } }
          Text {
            id: nameText
            anchors.centerIn: parent
            text: {
              var label = model.wsName ? model.wsName : ("WORKSPACE " + model.wsIdx)
              return label.toUpperCase() + "  ·  " + model.output
            }
            font.family: Style.fontFamily
            font.pixelSize: 12
            font.weight: Font.Bold
            font.letterSpacing: 0.5
            color: workspaceSwitcher.colors ? workspaceSwitcher.colors.tertiary : "#8bceff"
            elide: Text.ElideMiddle
            maximumLineCount: 1
            width: Math.min(implicitWidth, delegateItem.width - 60)
          }
        }


        // Window list for current workspace
        Column {
          anchors.bottom: nameLabel.top
          anchors.bottomMargin: 8
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: 4
          visible: delegateItem.isCurrent && delegateItem.windowsList.length > 0
          opacity: delegateItem.isCurrent ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 200 } }

          Repeater {
            model: delegateItem.isCurrent ? delegateItem.windowsList : []

            Rectangle {
              width: winRow.width + 16
              height: 22
              radius: 4
              color: Qt.rgba(0, 0, 0, 0.65)
              anchors.horizontalCenter: parent.horizontalCenter

              Row {
                id: winRow
                anchors.centerIn: parent
                spacing: 6
                Text {
                  text: modelData.app_id || ""
                  font.family: Style.fontFamily
                  font.pixelSize: 10
                  font.weight: Font.Bold
                  color: modelData.is_focused
                    ? (workspaceSwitcher.colors ? workspaceSwitcher.colors.primary : "#4fc3f7")
                    : "#ffffff"
                }
                Text {
                  text: {
                    var t = modelData.title || ""
                    return t.length > 40 ? t.substring(0, 40) + "…" : t
                  }
                  font.family: Style.fontFamily
                  font.pixelSize: 10
                  color: Qt.rgba(1, 1, 1, 0.6)
                }
              }
            }
          }
        }


        // Window count badge
        Rectangle {
          anchors.bottom: parent.bottom
          anchors.bottomMargin: 8
          anchors.right: parent.right
          anchors.rightMargin: workspaceSwitcher.skewOffset + 8
          width: badgeText.width + 8
          height: 16
          radius: 4
          color: Qt.rgba(0, 0, 0, 0.75)
          border.width: 1
          border.color: workspaceSwitcher.colors ? Qt.rgba(workspaceSwitcher.colors.primary.r, workspaceSwitcher.colors.primary.g, workspaceSwitcher.colors.primary.b, 0.4) : Qt.rgba(1, 1, 1, 0.2)
          z: 10

          Text {
            id: badgeText
            anchors.centerIn: parent
            text: model.windowCount + " WIN"
            font.family: Style.fontFamily
            font.pixelSize: 9
            font.weight: Font.Bold
            font.letterSpacing: 0.5
            color: workspaceSwitcher.colors ? workspaceSwitcher.colors.tertiary : "#8bceff"
          }
        }


        // Workspace index badge
        Rectangle {
          anchors.bottom: parent.bottom
          anchors.bottomMargin: 8
          anchors.left: parent.left
          anchors.leftMargin: workspaceSwitcher.skewOffset + 8
          width: 20
          height: 20
          radius: 10
          color: model.isActive
            ? (workspaceSwitcher.colors ? workspaceSwitcher.colors.primary : "#4fc3f7")
            : Qt.rgba(0, 0, 0, 0.75)
          border.width: model.isActive ? 0 : 1
          border.color: workspaceSwitcher.colors ? Qt.rgba(workspaceSwitcher.colors.primary.r, workspaceSwitcher.colors.primary.g, workspaceSwitcher.colors.primary.b, 0.4) : Qt.rgba(1, 1, 1, 0.2)
          z: 10

          Text {
            anchors.centerIn: parent
            text: model.wsIdx
            font.family: Style.fontFamily
            font.pixelSize: 10
            font.weight: Font.Bold
            color: model.isActive
              ? (workspaceSwitcher.colors ? workspaceSwitcher.colors.primaryText : "#000")
              : (workspaceSwitcher.colors ? workspaceSwitcher.colors.tertiary : "#8bceff")
          }
        }


        // Click and hover interaction
        MouseArea {
          id: itemMouseArea
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton
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
            if (delegateItem.isCurrent) {
              workspaceSwitcher.switchToWorkspace(model.wsIdx, model.output)
            } else {
              sliceListView.currentIndex = index
            }
          }
        }
      }
    }

  }


  // Secondary monitor overlays to capture keyboard input from any screen
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: secondarySwitcherPanel

      property var modelData
      property bool isMainMonitor: modelData.name === workspaceSwitcher.mainMonitor || (Quickshell.screens.length === 1)

      screen: modelData
      visible: workspaceSwitcher.showing && !isMainMonitor
      color: "transparent"

      anchors {
        top: true
        bottom: true
        left: true
        right: true
      }

      WlrLayershell.namespace: "workspace-switcher-secondary"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: (workspaceSwitcher.showing && !isMainMonitor) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

      exclusionMode: ExclusionMode.Ignore

      DimOverlay {
        active: workspaceSwitcher.cardVisible
        dimOpacity: 0.5
        onClicked: workspaceSwitcher.showing = false
      }

      FocusScope {
        anchors.fill: parent
        focus: workspaceSwitcher.showing && !isMainMonitor

        Keys.onEscapePressed: workspaceSwitcher.showing = false
        Keys.onReturnPressed: {
          if (sliceListView.currentIndex >= 0 && sliceListView.currentIndex < filteredModel.count) {
            var ws = filteredModel.get(sliceListView.currentIndex)
            workspaceSwitcher.switchToWorkspace(ws.wsIdx, ws.output)
          }
        }

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Left) {
            if (sliceListView.currentIndex > 0) sliceListView.currentIndex--
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_Right) {
            if (sliceListView.currentIndex < filteredModel.count - 1) sliceListView.currentIndex++
            event.accepted = true
            return
          }
          var num = -1
          if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
            num = event.key - Qt.Key_1
          }
          if (num >= 0 && num < filteredModel.count) {
            var ws = filteredModel.get(num)
            workspaceSwitcher.switchToWorkspace(ws.wsIdx, ws.output)
            event.accepted = true
          }
        }
      }
    }
  }
}
