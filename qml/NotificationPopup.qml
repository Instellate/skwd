import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Notifications
import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import "components"

// Notification popup toasts and sliding notification center panel
Scope {
  id: notifScope

  // State and layout properties
  property var colors
  property var notifications
  property string mainMonitor: Config.mainMonitor
  property bool barVisible: false
  property int barHeight: 32


  property int effectiveTopMargin: barVisible ? popupTopMargin + barHeight : popupTopMargin


  // Center panel toggle and dismiss-all helper
  property bool centerOpen: false
  function toggleCenter() { centerOpen = !centerOpen }
  function dismissAll() {
    if (!notifications) return
    var vals = notifications.values
    for (var i = vals.length - 1; i >= 0; i--) {
      vals[i].dismiss()
    }
  }


  property int popupWidth: 380
  property int popupSpacing: 8
  property int popupMaxVisible: 4
  property int popupRightMargin: 16
  property int popupTopMargin: 12


  property int notifCount: notifications ? notifications.values.length : 0
  property bool hasNotifs: notifCount > 0


  // Overlay panel (full-screen when center open, popup-sized otherwise)
  PanelWindow {
    id: notifPanel

    screen: Quickshell.screens.find(s => s.name === notifScope.mainMonitor) ?? Quickshell.screens[0]

    anchors {
      top: true
      right: true
    }


    implicitWidth: notifScope.centerOpen
      ? (screen ? screen.width : 1920)
      : notifScope.popupWidth + notifScope.popupRightMargin * 2
    implicitHeight: notifScope.centerOpen
      ? (screen ? screen.height : 1080)
      : Math.max(1, notifScope.effectiveTopMargin + popupColumn.childrenRect.height + notifScope.popupSpacing * 2)

    color: "transparent"

    visible: notifScope.centerOpen || popupColumn.childrenRect.height > 0

    WlrLayershell.namespace: "notifications"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: notifScope.centerOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    exclusionMode: ExclusionMode.Ignore


    // Dim background when center panel is open
    DimOverlay {
      active: notifScope.centerOpen
      visible: notifScope.centerOpen
      onClicked: notifScope.centerOpen = false

      Item {
        focus: notifScope.centerOpen
        Keys.onEscapePressed: notifScope.centerOpen = false
      }
    }


    // Notification center slide-in card
    Item {
      id: centerCard
      visible: notifScope.centerOpen
      anchors.right: parent.right
      anchors.rightMargin: notifScope.popupRightMargin
      anchors.top: parent.top
      anchors.topMargin: notifScope.popupTopMargin
      anchors.bottom: parent.bottom
      anchors.bottomMargin: notifScope.popupTopMargin
      width: notifScope.popupWidth

      property bool animateIn: notifScope.centerOpen

      onAnimateInChanged: {
        if (animateIn) {
          centerBorderBox.animate()
          centerBg.opacity = 0
          centerBgFadeIn.start()
        } else {
          centerBorderBox.reset()
          centerBg.opacity = 0
        }
      }

      property color lineColor: notifScope.colors ? notifScope.colors.primary : "#ffb4ab"

      Rectangle {
        id: centerBg
        anchors.fill: parent
        radius: 12
        color: notifScope.colors
          ? Qt.rgba(notifScope.colors.surface.r,
                    notifScope.colors.surface.g,
                    notifScope.colors.surface.b, 0.88)
          : Qt.rgba(0.1, 0.12, 0.18, 0.88)
        opacity: 0
      }

      NumberAnimation { id: centerBgFadeIn; target: centerBg; property: "opacity"; from: 0; to: 1; duration: 600; easing.type: Easing.OutCubic }

      AnimatedBorderBox {
        id: centerBorderBox
        lineColor: centerCard.lineColor
        duration: 600
      }


      MouseArea { anchors.fill: parent }


      // Center header with title and clear-all button
      RowLayout {
        id: centerHeader
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 16
        height: 36

        Text {
          text: "NOTIFICATIONS"
          font.family: Style.fontFamily
          font.weight: Font.Bold
          font.pixelSize: 14
          color: notifScope.colors ? notifScope.colors.primary : "#ffb4ab"
          Layout.fillWidth: true
        }


        Rectangle {
          width: dismissAllText.implicitWidth + 16
          height: 24
          radius: 12
          color: dismissAllMouse.containsMouse
            ? (notifScope.colors ? notifScope.colors.primary : "#ffb4ab")
            : "transparent"
          border.width: 1
          border.color: notifScope.colors ? notifScope.colors.primary : "#ffb4ab"

          Text {
            id: dismissAllText
            anchors.centerIn: parent
            text: "CLEAR ALL"
            font.family: Style.fontFamily
            font.weight: Font.Bold
            font.pixelSize: 11
            color: dismissAllMouse.containsMouse
              ? (notifScope.colors ? notifScope.colors.primaryForeground : "#690005")
              : (notifScope.colors ? notifScope.colors.primary : "#ffb4ab")
          }

          MouseArea {
            id: dismissAllMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: notifScope.dismissAll()
          }
        }
      }


      // Scrollable notification list
      Flickable {
        anchors.top: centerHeader.bottom
        anchors.topMargin: 8
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 12
        clip: true
        contentHeight: centerColumn.implicitHeight
        flickableDirection: Flickable.VerticalFlick
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: centerColumn
          width: parent.width
          spacing: notifScope.popupSpacing

          Repeater {
            model: notifScope.notifications

            delegate: NotificationCard {
              required property var modelData
              notification: modelData
              colors: notifScope.colors
              cardWidth: centerColumn.width
              isPopup: false
            }
          }
        }


        Text {
          anchors.centerIn: parent
          visible: !notifScope.hasNotifs
          text: "NO NOTIFICATIONS"
          font.family: Style.fontFamily
          font.weight: Font.Bold
          font.pixelSize: 16
          color: notifScope.colors ? notifScope.colors.outline : "#666666"
        }
      }
    }


    // Popup toast stack (top-right corner)
    Column {
      id: popupColumn
      visible: !notifScope.centerOpen
      anchors.right: parent.right
      anchors.rightMargin: notifScope.popupRightMargin
      anchors.top: parent.top
      anchors.topMargin: notifScope.effectiveTopMargin
      width: notifScope.popupWidth
      spacing: notifScope.popupSpacing


      Repeater {
        id: popupRepeater
        model: notifScope.notifications

        delegate: NotificationCard {
          required property var modelData
          required property int index
          notification: modelData
          colors: notifScope.colors
          cardWidth: notifScope.popupWidth
          isPopup: true

          visible: index >= notifScope.notifCount - notifScope.popupMaxVisible
        }
      }
    }
  }


  // Inline notification card component
  component NotificationCard: Item {
    id: card

    // Card properties
    property var notification
    property var colors
    property int cardWidth: 380
    property bool isPopup: true

    width: cardWidth

    property real cardNaturalHeight: contentColumn.implicitHeight + 26
    height: cardNaturalHeight
    clip: true


    property bool dismissing: false


    opacity: 0
    transform: Translate { id: cardTranslate; x: 40 }

    Component.onCompleted: {
      cardEntryAnim.start()
      if (isPopup) autoExpireTimer.start()
    }


    // Entry slide-in animation
    ParallelAnimation {
      id: cardEntryAnim
      NumberAnimation { target: card; property: "opacity"; from: 0; to: 1; duration: 350; easing.type: Easing.OutCubic }
      NumberAnimation { target: cardTranslate; property: "x"; from: 40; to: 0; duration: 350; easing.type: Easing.OutCubic }
      NumberAnimation { target: cardBg; property: "opacity"; from: 0; to: 1; duration: 350; easing.type: Easing.OutCubic }
      NumberAnimation { target: card; property: "lineProgress"; from: 0; to: 1; duration: 600; easing.type: Easing.OutCubic }
    }

    // Exit slide-out and collapse animation
    SequentialAnimation {
      id: cardExitAnim

      ParallelAnimation {
        NumberAnimation { target: card; property: "opacity"; to: 0; duration: 300; easing.type: Easing.InCubic }
        NumberAnimation { target: cardTranslate; property: "x"; to: 40; duration: 300; easing.type: Easing.InCubic }
        NumberAnimation { target: cardBg; property: "opacity"; to: 0; duration: 300; easing.type: Easing.InCubic }
        NumberAnimation { target: card; property: "lineProgress"; to: 0; duration: 400; easing.type: Easing.InCubic }
      }


      NumberAnimation { target: card; property: "height"; to: 0; duration: 200; easing.type: Easing.InOutCubic }

      ScriptAction {
        script: {
          if (card.notification) card.notification.dismiss()
        }
      }
    }


    function animateDismiss() {
      if (dismissing) return
      dismissing = true
      autoExpireTimer.stop()
      cardEntryAnim.stop()
      cardExitAnim.start()
    }

    // Auto-expire timer (pauses on hover)
    Timer {
      id: autoExpireTimer
      interval: {
        if (card.notification && card.notification.expireTimeout > 0)
          return card.notification.expireTimeout
        return Config.notificationExpireMs
      }
      running: false
      onTriggered: card.animateDismiss()
    }


    // Pause auto-expire on hover
    property bool hovered: cardMouse.containsMouse
    onHoveredChanged: {
      if (!isPopup) return
      if (hovered) {
        autoExpireTimer.stop()
      } else if (!dismissing) {
        autoExpireTimer.restart()
      }
    }

    property real lineProgress: 0
    property color lineColor: colors ? colors.primary : "#ffb4ab"

    Rectangle {
      id: cardBg
      anchors.fill: parent
      radius: 10
      color: colors
        ? Qt.rgba(colors.surface.r, colors.surface.g, colors.surface.b, 0.88)
        : Qt.rgba(0.1, 0.12, 0.18, 0.88)
      opacity: 0
    }

    AnimatedBorderBox {
      lineColor: card.lineColor
      progress: card.lineProgress
      lineOpacity: card.lineProgress
    }


    // Card content layout (app name, summary, body, actions)
    Item {
      id: cardContent
      anchors.fill: parent
      anchors.margins: 1

      ColumnLayout {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 12
        spacing: 4


        RowLayout {
          Layout.fillWidth: true

          Text {
            text: card.notification ? (card.notification.appName || "Notification") : "Notification"
            font.family: Style.fontFamily
            font.weight: Font.DemiBold
            font.pixelSize: 11
            color: card.colors ? card.colors.primary : "#ffb4ab"
            opacity: 0.9
            Layout.fillWidth: true
          }


          Text {
            text: "✕"
            font.pixelSize: 12
            color: closeMouse.containsMouse
              ? (card.colors ? card.colors.primary : "#ffb4ab")
              : (card.colors ? card.colors.outline : "#666")

            MouseArea {
              id: closeMouse
              anchors.fill: parent
              anchors.margins: -4
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: card.animateDismiss()
            }
          }
        }


        Text {
          text: card.notification ? (card.notification.summary || "") : ""
          font.family: Style.fontFamily
          font.weight: Font.DemiBold
          font.pixelSize: 14
          color: card.colors ? card.colors.tertiary : "#8bceff"
          wrapMode: Text.Wrap
          Layout.fillWidth: true
          visible: text !== ""
        }


        Text {
          text: card.notification ? (card.notification.body || "") : ""
          font.family: Style.fontFamily
          font.pixelSize: 12
          color: card.colors ? card.colors.surfaceVariantText : "#e2beba"
          opacity: 0.85
          wrapMode: Text.Wrap
          Layout.fillWidth: true
          visible: text !== ""
          maximumLineCount: card.isPopup ? 3 : 6
          elide: Text.ElideRight
        }


        // Action buttons row
        RowLayout {
          Layout.fillWidth: true
          spacing: 6
          visible: card.notification && card.notification.actions && card.notification.actions.length > 0

          Repeater {
            model: card.notification ? card.notification.actions : []

            delegate: Rectangle {
              required property var modelData
              property var action: modelData

              width: actionLabel.implicitWidth + 16
              height: 24
              radius: 12
              color: actionMouse.containsMouse
                ? (card.colors ? card.colors.primary : "#ffb4ab")
                : (card.colors ? Qt.rgba(card.colors.secondaryContainer.r, card.colors.secondaryContainer.g, card.colors.secondaryContainer.b, 0.5) : "#333")

              Text {
                id: actionLabel
                anchors.centerIn: parent
                text: action.text || ""
                font.family: Style.fontFamily
                font.weight: Font.DemiBold
                font.pixelSize: 11
                color: actionMouse.containsMouse
                  ? (card.colors ? card.colors.primaryForeground : "#690005")
                  : (card.colors ? card.colors.tertiary : "#8bceff")
              }

              MouseArea {
                id: actionMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: action.invoke()
              }
            }
          }
        }
      }
    }


    MouseArea {
      id: cardMouse
      anchors.fill: parent
      z: -1
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: card.animateDismiss()
    }
  }
}
