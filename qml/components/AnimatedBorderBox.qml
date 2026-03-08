import QtQuick

// Animated border-drawing effect that traces all four edges
Item {
  id: root
  anchors.fill: parent

  // Configuration properties
  property color lineColor: "#8BC34A"
  property int lineThickness: 2
  property int duration: 800
  property real progress: internal.lineProgress
  property real lineOpacity: progress > 0 ? internal.lineOpacity : 0

  // Start/reset animation functions
  function animate() {
    lineAnim.stop()
    internal.lineProgress = 0
    internal.lineOpacity = 0
    lineAnim.start()
  }

  function reset() {
    lineAnim.stop()
    internal.lineProgress = 0
    internal.lineOpacity = 0
  }

  // Internal animation state
  QtObject {
    id: internal
    property real lineProgress: 0
    property real lineOpacity: 0
  }

  // Four edge rectangles (top, bottom, left, right)
  Rectangle {
    height: root.lineThickness; radius: 1
    width: parent.width * root.progress
    color: root.lineColor
    anchors.top: parent.top; anchors.right: parent.right
    opacity: root.lineOpacity
  }
  Rectangle {
    height: root.lineThickness; radius: 1
    width: parent.width * root.progress
    color: root.lineColor
    anchors.bottom: parent.bottom; anchors.left: parent.left
    opacity: root.lineOpacity
  }
  Rectangle {
    width: root.lineThickness; radius: 1
    height: parent.height * root.progress
    color: root.lineColor
    anchors.left: parent.left; anchors.top: parent.top
    opacity: root.lineOpacity
  }
  Rectangle {
    width: root.lineThickness; radius: 1
    height: parent.height * root.progress
    color: root.lineColor
    anchors.right: parent.right; anchors.bottom: parent.bottom
    opacity: root.lineOpacity
  }

  // Parallel progress + opacity animation sequence
  ParallelAnimation {
    id: lineAnim
    NumberAnimation { target: internal; property: "lineProgress"; from: 0; to: 1; duration: root.duration; easing.type: Easing.OutCubic }
    NumberAnimation { target: internal; property: "lineOpacity"; from: 0; to: 1; duration: root.duration }
  }
}
