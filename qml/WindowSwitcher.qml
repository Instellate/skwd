import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import "components"

// Alt-Tab window switcher (grid layout variant)
Scope {
  id: switcherScope

  // External bindings
  property var colors
  property bool showing: false


  property string mainMonitor: Config.mainMonitor


  // Window list and selection state
  property var windowList: []
  property int windowCount: windowList.length
  property int selectedIndex: 0


  // Grid layout constants
  property int itemWidth: 280
  property int itemHeight: 80
  property int maxColumns: 5
  property int itemSpacing: 12
  property int cardPadding: 20


  property bool cardVisible: false


  property bool preserveIndex: false


  // Open/cancel/refresh/confirm actions
  function open() {
    if (!showing) {
      selectedIndex = 0
      preserveIndex = false
      refreshWindows()
      showing = true
    }
  }


  function cancel() {
    showing = false
  }


  function refreshWindows() {
    windowLoader.running = true
  }


  // Focus selected window via wm-action
  function confirm() {
    if (showing && windowList.length > 0 && selectedIndex >= 0 && selectedIndex < windowList.length) {
      var win = windowList[selectedIndex]
      focusProcess.command = [Config.scriptsDir + "/bash/wm-action", "focus-window", win.id.toString()]
      focusProcess.running = true
    }
    showing = false
  }

  Process {
    id: focusProcess
    command: ["true"]
  }


  Process {
    id: closeWindowProcess
    command: ["true"]
  }

  // Close selected window and refresh list
  function closeSelected() {
    if (windowList.length > 0 && selectedIndex >= 0 && selectedIndex < windowList.length) {
      var win = windowList[selectedIndex]
      closeWindowProcess.command = [Config.scriptsDir + "/bash/wm-action", "close-window", win.id.toString()]
      closeWindowProcess.running = true

      preserveIndex = true
      refreshTimer.restart()
    }
  }

  Timer {
    id: refreshTimer
    interval: 100
    onTriggered: {
      switcherScope.refreshWindows()
    }
  }


  // Navigate selection
  function next() {
    if (windowList.length > 0) {
      selectedIndex = (selectedIndex + 1) % windowList.length
    }
  }


  function prev() {
    if (windowList.length > 0) {
      selectedIndex = (selectedIndex - 1 + windowList.length) % windowList.length
    }
  }

  onShowingChanged: {
    if (showing) {
      cardShowTimer.restart()
    } else {
      cardVisible = false
    }
  }

  Timer {
    id: cardShowTimer
    interval: 50
    onTriggered: switcherScope.cardVisible = true
  }


  // Parse niri window list output
  Process {
    id: windowLoader
    command: [Config.scriptsDir + "/bash/wm-action", "list-windows"]

    property string output: ""

    stdout: SplitParser {
      splitMarker: ""
      onRead: data => {
        windowLoader.output += data
      }
    }

    onExited: (exitCode, exitStatus) => {
      try {


        var lines = windowLoader.output.split("\n")
        var windows = []
        var current = null

        for (var i = 0; i < lines.length; i++) {
          var line = lines[i]
          var windowMatch = line.match(/^Window ID (\d+):(.*)/)
          if (windowMatch) {
            if (current) windows.push(current)
            current = {
              id: parseInt(windowMatch[1]),
              title: "",
              class: "",
              workspace: { id: 0, name: "" },
              focused: line.includes("(focused)")
            }
          } else if (current) {
            var trimmed = line.trim()
            if (trimmed.startsWith('Title: "')) {
              current.title = trimmed.slice(8, -1)
            } else if (trimmed.startsWith('App ID: "')) {
              current.class = trimmed.slice(9, -1)
            } else if (trimmed.startsWith('Workspace ID: ')) {
              var wsId = parseInt(trimmed.slice(14))
              current.workspace = { id: wsId, name: wsId.toString() }
            }
          }
        }
        if (current) windows.push(current)


        windows.sort(function(a, b) {
          if (a.focused && !b.focused) return -1
          if (!a.focused && b.focused) return 1
          return 0
        })

        switcherScope.windowList = windows
        switcherScope.windowCount = windows.length
        if (!switcherScope.preserveIndex) {
          switcherScope.selectedIndex = 0
        } else {
          if (switcherScope.selectedIndex >= windows.length) {
            switcherScope.selectedIndex = Math.max(0, windows.length - 1)
          }
          switcherScope.preserveIndex = false
        }
      } catch (e) {
        console.log("Failed to parse window list:", e)
        switcherScope.windowList = []
      }
      windowLoader.output = ""
    }
  }


  // Per-screen overlay with keyboard handling
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: switcherPanel

      property var modelData
      property bool isMainMonitor: modelData.name === switcherScope.mainMonitor || (Quickshell.screens.length === 1)

      screen: modelData

      anchors {
        top: true
        bottom: true
        left: true
        right: true
      }

      visible: switcherScope.showing
      color: "transparent"

      WlrLayershell.namespace: "window-switcher"
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.keyboardFocus: switcherScope.showing ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

      exclusionMode: ExclusionMode.Ignore

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.01)
      }

      DimOverlay {
        active: switcherScope.cardVisible
        onClicked: switcherScope.cancel()
      }


      // Keyboard proxy for secondary monitors
      FocusScope {
        id: keyboardProxySwitcher
        anchors.fill: parent
        focus: switcherScope.showing && !isMainMonitor
        activeFocusOnTab: false

        Keys.onPressed: event => {
          if (event.key === Qt.Key_Escape) {
            switcherScope.cancel()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            switcherScope.confirm()
            event.accepted = true
          } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            if ((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab) {
              switcherScope.prev()
            } else {
              switcherScope.next()
            }
            event.accepted = true
          } else if (event.key === Qt.Key_Left) {
            switcherScope.prev()
            event.accepted = true
          } else if (event.key === Qt.Key_Right) {
            switcherScope.next()
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            var cols = Math.min(switcherScope.windowList.length, switcherScope.maxColumns)
            var newIndex = switcherScope.selectedIndex - cols
            if (newIndex >= 0) switcherScope.selectedIndex = newIndex
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            var cols2 = Math.min(switcherScope.windowList.length, switcherScope.maxColumns)
            var newIndex2 = switcherScope.selectedIndex + cols2
            if (newIndex2 < switcherScope.windowList.length) switcherScope.selectedIndex = newIndex2
            event.accepted = true
          }
        }

        Keys.onReleased: event => {
          if (event.key === Qt.Key_Alt) {
            switcherScope.confirm()
            event.accepted = true
          }
        }
      }

      // Main monitor card with animated border
      Item {
        id: switcherCard
        visible: isMainMonitor && switcherScope.cardVisible
        anchors.centerIn: parent

        property int columns: Math.max(1, Math.min(switcherScope.windowCount, switcherScope.maxColumns))
        property int rows: Math.max(1, Math.ceil(switcherScope.windowCount / switcherScope.maxColumns))

        property int cardWidth: columns * (switcherScope.itemWidth + switcherScope.itemSpacing) + switcherScope.cardPadding * 2
        property int cardHeight: rows * (switcherScope.itemHeight + switcherScope.itemSpacing) + switcherScope.cardPadding * 2

        width: cardWidth
        height: cardHeight

        Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

        property bool animateIn: switcherScope.cardVisible && isMainMonitor

        onAnimateInChanged: {
          if (animateIn) {
            borderBox.animate()
            bgRect.opacity = 0
            bgFadeIn.start()
            focusTimer.restart()
          } else {
            borderBox.reset()
            bgRect.opacity = 0
          }
        }

        Timer {
          id: focusTimer
          interval: 100
          onTriggered: keyHandler.forceActiveFocus()
        }

        Rectangle {
          id: bgRect
          anchors.fill: parent
          color: switcherScope.colors ? Qt.rgba(switcherScope.colors.surfaceContainer.r,
                                                 switcherScope.colors.surfaceContainer.g,
                                                 switcherScope.colors.surfaceContainer.b, 0.45)
                                      : Qt.rgba(0.1, 0.12, 0.18, 0.45)
          opacity: 0
        }

        NumberAnimation { id: bgFadeIn; target: bgRect; property: "opacity"; from: 0; to: 1; duration: 1000; easing.type: Easing.OutCubic }

        AnimatedBorderBox {
          id: borderBox
          lineColor: switcherScope.colors ? switcherScope.colors.primary : "#8BC34A"
          duration: 1000
        }


        MouseArea {
          anchors.fill: parent
          onClicked: {}
        }


        // Main monitor keyboard handler
        FocusScope {
          id: keyHandler
          anchors.fill: parent
          focus: switcherScope.showing && isMainMonitor
          activeFocusOnTab: false

          Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
              switcherScope.cancel()
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              switcherScope.confirm()
              event.accepted = true
            } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {

              if ((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab) {
                switcherScope.prev()
              } else {
                switcherScope.next()
              }
              event.accepted = true
            } else if (event.key === Qt.Key_Left) {
              switcherScope.prev()
              event.accepted = true
            } else if (event.key === Qt.Key_Right) {
              switcherScope.next()
              event.accepted = true
            } else if (event.key === Qt.Key_Up) {

              var cols = Math.min(switcherScope.windowList.length, switcherScope.maxColumns)
              var newIndex = switcherScope.selectedIndex - cols
              if (newIndex >= 0) {
                switcherScope.selectedIndex = newIndex
              }
              event.accepted = true
            } else if (event.key === Qt.Key_Down) {

              var cols2 = Math.min(switcherScope.windowList.length, switcherScope.maxColumns)
              var newIndex2 = switcherScope.selectedIndex + cols2
              if (newIndex2 < switcherScope.windowList.length) {
                switcherScope.selectedIndex = newIndex2
              }
              event.accepted = true
            }
          }

          Keys.onReleased: event => {

            if (event.key === Qt.Key_Alt) {
              switcherScope.confirm()
              event.accepted = true
            }
          }
        }


        // Window grid with item delegates
        GridView {
          id: windowGrid
          anchors.fill: parent
          anchors.margins: switcherScope.cardPadding

          cellWidth: switcherScope.itemWidth + switcherScope.itemSpacing
          cellHeight: switcherScope.itemHeight + switcherScope.itemSpacing

          model: switcherScope.windowList
          interactive: false
          clip: true


          remove: Transition {
            ParallelAnimation {
              NumberAnimation { property: "opacity"; to: 0; duration: 200; easing.type: Easing.OutQuad }
              NumberAnimation { property: "scale"; to: 0.8; duration: 200; easing.type: Easing.OutQuad }
            }
          }


          displaced: Transition {
            NumberAnimation { properties: "x,y"; duration: 250; easing.type: Easing.OutCubic }
          }


          add: Transition {
            ParallelAnimation {
              NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 200; easing.type: Easing.OutQuad }
              NumberAnimation { property: "scale"; from: 0.8; to: 1; duration: 200; easing.type: Easing.OutQuad }
            }
          }

          delegate: Item {
            id: delegateRoot
            width: switcherScope.itemWidth + switcherScope.itemSpacing
            height: switcherScope.itemHeight + switcherScope.itemSpacing

            Rectangle {
              id: windowItem
              width: switcherScope.itemWidth
              height: switcherScope.itemHeight
              anchors.centerIn: parent

              property bool isSelected: switcherScope.selectedIndex === index
              property bool isHovered: itemMouse.containsMouse

              color: isSelected
                   ? (switcherScope.colors ? Qt.rgba(switcherScope.colors.secondary.r, switcherScope.colors.secondary.g, switcherScope.colors.secondary.b, 0.35) : Qt.rgba(0.5, 0.5, 0.6, 0.35))
                   : isHovered
                     ? (switcherScope.colors ? Qt.rgba(switcherScope.colors.surfaceVariant.r, switcherScope.colors.surfaceVariant.g, switcherScope.colors.surfaceVariant.b, 0.2) : Qt.rgba(1, 1, 1, 0.1))
                     : "transparent"
              radius: 8

              Behavior on color { ColorAnimation { duration: 100 } }

              RowLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 12


                Text {
                  text: "?"
                  font.pixelSize: 32
                  font.family: Style.fontFamilyMono
                  color: windowItem.isSelected ? (switcherScope.colors ? switcherScope.colors.primary : "#8BC34A") : (switcherScope.colors ? switcherScope.colors.tertiary : "#aaa")
                  Layout.alignment: Qt.AlignVCenter
                  Behavior on color { ColorAnimation { duration: 100 } }
                }


                ColumnLayout {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  spacing: 2


                  Text {
                    Layout.fillWidth: true
                    text: (modelData.class || "?").toUpperCase()
                    font.family: Style.fontFamily
                    font.weight: Font.Bold
                    font.pixelSize: 14
                    color: windowItem.isSelected ? (switcherScope.colors ? switcherScope.colors.primary : "#8BC34A") : (switcherScope.colors ? switcherScope.colors.tertiary : "#aaa")
                    elide: Text.ElideRight
                    Behavior on color { ColorAnimation { duration: 100 } }
                  }


                  Text {
                    Layout.fillWidth: true
                    text: modelData.title
                    font.family: Style.fontFamily
                    font.pixelSize: 12
                    color: switcherScope.colors ? Qt.rgba(switcherScope.colors.tertiary.r, switcherScope.colors.tertiary.g, switcherScope.colors.tertiary.b, 0.7) : Qt.rgba(0.7, 0.7, 0.7, 0.7)
                    elide: Text.ElideRight
                    maximumLineCount: 1
                  }


                  Text {
                    text: "Workspace " + modelData.workspace.name
                    font.family: Style.fontFamily
                    font.pixelSize: 12
                    color: switcherScope.colors ? Qt.rgba(switcherScope.colors.tertiary.r, switcherScope.colors.tertiary.g, switcherScope.colors.tertiary.b, 0.5) : Qt.rgba(0.7, 0.7, 0.7, 0.5)
                  }
                }
              }

              MouseArea {
                id: itemMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: {
                  switcherScope.selectedIndex = index
                  switcherScope.confirm()
                }
                onEntered: switcherScope.selectedIndex = index
              }
            }
          }
        }


        Text {
          anchors.centerIn: parent
          visible: switcherScope.windowCount === 0
          text: "NO WINDOWS"
          font.family: Style.fontFamily
          font.weight: Font.Bold
          font.pixelSize: 18
          color: switcherScope.colors ? switcherScope.colors.outline : "#666666"
        }
      }
    }
  }
}
