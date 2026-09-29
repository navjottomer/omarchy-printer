import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Printer status, toner and the print queue. Fed by bin/omarchy-printer, one
// long-lived process that talks to CUPS (and, for fresh toner and paper
// readings, to network printers directly) and prints a JSON line whenever
// something changes. Styled like navjottomer.sysmon: theme colours, stock
// qs.Ui parts.
Panel {
  id: root

  moduleName: "navjottomer.printer"
  ipcTarget: "navjottomer.printer"

  readonly property string ff: bar ? bar.fontFamily : Style.font.family
  readonly property color dimForeground: Qt.darker(barForeground, 1.4)
  readonly property color urgent: bar ? bar.urgent : Color.urgent

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---------- Settings ----------
  function boolSetting(name, fallback) {
    var v = settings ? settings[name] : undefined
    if (v === undefined || v === null || v === "") return fallback
    return v === true || v === "true"
  }
  readonly property bool realTonerColors: !(settings && settings.tonerColors === "theme")
  readonly property bool notifications: boolSetting("notifications", true)

  // ---------- Data ----------
  property var status: ({ ok: false, printers: [], jobs: [] })
  property string chosenName: ""

  readonly property var printers: status.printers || []
  readonly property var printer: {
    var list = printers
    if (!list.length) return null
    var want = chosenName || status["default"] || ""
    for (var i = 0; i < list.length; i++) if (list[i].name === want) return list[i]
    return list[0]
  }
  readonly property var jobs: {
    var out = []
    var all = status.jobs || []
    for (var i = 0; i < all.length; i++)
      if (printer && all[i].printer === printer.name) out.push(all[i])
    return out
  }
  readonly property var myJobs: jobs.filter(function(j) { return j.mine })

  readonly property bool hasProblem: !!printer && (printer.problems || []).some(function(p) {
    return p.indexOf("toner low") < 0
  })
  readonly property bool paused: !!printer && (printer.status === "Paused" || printer.status === "Offline")

  readonly property string pluginDir: {
    var s = String(Qt.resolvedUrl("."))
    return s.indexOf("file://") === 0 ? s.substring(7) : s
  }
  readonly property string safeName: printer && /^[A-Za-z0-9_.@-]{1,127}$/.test(printer.name) ? printer.name : ""

  function timeAgo(epoch) {
    var s = Math.max(0, Math.floor(Date.now() / 1000) - Number(epoch || 0))
    if (!epoch) return ""
    if (s < 90) return "just now"
    if (s < 3600) return Math.round(s / 60) + " min ago"
    if (s < 86400) return Math.round(s / 3600) + " h ago"
    return Math.round(s / 86400) + " d ago"
  }

  function visibleTonerColor(hex) {
    var c = Qt.color(hex)
    var luma = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    return luma < 0.25 ? root.barForeground : c
  }

  function jobState(j) {
    if (j.state === "printing") return j.pages > 0 ? "Printing · page " + (j.pages + 1) : "Printing"
    if (j.state === "held") return "Held"
    if (j.state === "stopped") return "Stopped"
    return "Waiting"
  }

  // ---------- Feed ----------
  Process {
    id: feed
    running: true
    command: [root.pluginDir + "bin/omarchy-printer"].concat(root.notifications ? [] : ["--no-notify"])
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) {
        // The script caps each record at 32 KiB; anything longer is not ours.
        if (line.length > 65536) return
        try {
          var d = JSON.parse(String(line))
          if (d && typeof d === "object") root.status = d
        } catch (e) { }
      }
    }
  }

  function refresh() {
    if (feed.running) feed.write("refresh\n")
  }

  // ---------- Actions ----------
  // Commands run with fixed argv (no shell); the feed is refreshed after each.
  Process {
    id: action
    running: false
    command: []
    onExited: Qt.callLater(root.refresh)
  }

  function run(argv) {
    if (action.running) return
    action.command = argv
    action.running = true
  }

  function cancelJob(id) {
    if (/^[0-9]{1,9}$/.test(String(id))) run(["cancel", String(id)])
  }

  function cancelMine() {
    var ids = myJobs.map(function(j) { return String(j.id) }).filter(function(id) { return /^[0-9]{1,9}$/.test(id) })
    if (ids.length) run(["cancel"].concat(ids))
  }

  // Pausing needs admin rights in CUPS; pkexec shows the shell's password prompt.
  function togglePause() {
    if (!safeName) return
    close()
    run(["pkexec", paused ? "/usr/bin/cupsenable" : "/usr/bin/cupsdisable", safeName])
  }

  property bool testArmed: false
  Timer { id: disarm; interval: 3000; onTriggered: root.testArmed = false }
  function printTestPage() {
    if (!safeName) return
    if (!testArmed) { testArmed = true; disarm.restart(); return }
    testArmed = false
    run(["lp", "-d", safeName, "-t", "Test page", "/usr/share/cups/data/testprint"])
  }

  function openWeb() {
    if (printer && /^https?:\/\/[A-Za-z0-9.-]+\/$/.test(printer.web)) {
      Quickshell.execDetached(["xdg-open", printer.web])
      close()
    }
  }

  function openSettings() {
    Quickshell.execDetached(["uwsm-app", "--", "system-config-printer"])
    close()
  }

  onOpenedChanged: if (opened) { testArmed = false; refresh() }

  // ---------- Bar icon ----------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // printer / printer-off (nf-md)
    text: !root.printer || root.paused ? "\u{f0e5d}" : "\u{f042a}"
    active: root.hasProblem
    dimmed: !root.printer || root.paused
    tooltipText: !root.printer ? "No printer"
      : root.printer.info + " · " + (root.hasProblem ? root.printer.problems[0] : root.printer.status)
        + (root.jobs.length ? " · " + root.jobs.length + (root.jobs.length === 1 ? " job" : " jobs") : "")
    onPressed: function(b) {
      if (b === Qt.RightButton) root.openSettings()
      else root.toggle()
    }
  }

  // ---------- Pieces ----------
  // "key ........ value" line, as in sysmon.
  component InfoRow: Item {
    id: infoRow
    property string icon: ""
    property string key: ""
    property string value: ""
    property color valueColor: root.barForeground

    width: parent ? parent.width : 0
    implicitHeight: Math.max(keyText.implicitHeight, valueText.implicitHeight)

    Text {
      id: iconText
      width: Style.space(13)
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: infoRow.icon
      color: root.dimForeground
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: keyText
      anchors.left: iconText.right
      anchors.leftMargin: Style.space(8)
      anchors.right: valueText.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: infoRow.key
      elide: Text.ElideRight
      color: root.dimForeground
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: valueText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: infoRow.value
      color: infoRow.valueColor
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
    }
  }

  // ---------- Panel ----------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- No printer / CUPS down ----------
        Text {
          visible: !root.printer
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.status.ok === false && root.status.error ? root.status.error : "No printers set up"
          color: root.dimForeground
          font.family: root.ff
          font.pixelSize: Style.font.bodySmall
        }

        // ---------- Printer picker (more than one printer) ----------
        Flow {
          visible: root.printers.length > 1
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.printers.length
            Button {
              required property int index
              readonly property var p: root.printers[index]
              text: p ? p.info : ""
              fontSize: Style.font.caption
              fontFamily: root.ff
              foreground: root.barForeground
              selected: !!root.printer && !!p && p.name === root.printer.name
              bordered: true
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.chosenName = p.name
            }
          }
        }

        // ---------- Header: name, status, paper ----------
        Item {
          visible: !!root.printer
          width: parent.width
          implicitHeight: Math.max(headLeft.implicitHeight, headRight.implicitHeight)

          Column {
            id: headLeft
            anchors.left: parent.left
            anchors.right: headRight.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: root.printer ? root.printer.info : ""
              color: root.barForeground
              font.family: root.ff
              font.pixelSize: Style.font.subtitle
            }

            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: !root.printer ? ""
                : root.hasProblem ? root.printer.problems.filter(function(p) { return p.indexOf("toner low") < 0 }).join(" · ")
                : root.printer.status + (root.printer.message ? " · " + root.printer.message : "")
              color: root.hasProblem ? root.urgent : root.dimForeground
              font.family: root.ff
              font.pixelSize: Style.font.caption
            }
          }

          Column {
            id: headRight
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              anchors.right: parent.right
              visible: !!root.printer && root.printer.media !== ""
              textFormat: Text.PlainText
              text: "\u{f0219}  " + (root.printer ? root.printer.media : "") // nf-md-file
              color: root.barForeground
              font.family: root.ff
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              anchors.right: parent.right
              visible: !!root.printer && root.printer.name === root.status["default"]
              textFormat: Text.PlainText
              text: "Default"
              color: root.dimForeground
              font.family: root.ff
              font.pixelSize: Style.font.caption
            }
          }
        }

        PanelSeparator { visible: !!root.printer && root.printer.markers.length > 0; foreground: root.barForeground }

        // ---------- Toner ----------
        Column {
          visible: !!root.printer && root.printer.markers.length > 0
          width: parent.width
          spacing: Style.space(8)

          Item {
            width: parent.width
            implicitHeight: tonerTitle.implicitHeight

            PanelSectionHeader {
              id: tonerTitle
              text: "TONER"
              foreground: root.barForeground
              fontFamily: root.ff
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: tonerTitle.verticalCenter
              visible: !!root.printer && root.printer.readingsAt > 0
              textFormat: Text.PlainText
              text: root.printer ? root.timeAgo(root.printer.readingsAt) : ""
              color: root.dimForeground
              font.family: root.ff
              font.pixelSize: Style.font.caption
            }
          }

          Repeater {
            model: root.printer ? root.printer.markers.length : 0

            Item {
              required property int index
              readonly property var m: root.printer ? root.printer.markers[index] || ({}) : ({})
              readonly property bool low: m.level >= 0 && m.level <= m.low
              readonly property bool known: m.level >= 0

              width: parent.width
              implicitHeight: Math.max(tonerName.implicitHeight, tonerPct.implicitHeight)

              Text {
                id: tonerName
                width: Style.space(64)
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: m.name || ""
                color: root.dimForeground
                font.family: root.ff
                font.pixelSize: Style.font.bodySmall
              }

              Item {
                anchors.left: tonerName.right
                anchors.right: tonerPct.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.space(2)
                  color: root.barForeground
                  opacity: 0.06
                }

                Rectangle {
                  height: parent.height
                  radius: Style.space(2)
                  width: parent.width * Math.max(0, Math.min(100, Number(m.level) || 0)) / 100
                  // The printer's own colour for each toner, or the theme accent.
                  // Black toner would vanish on a dark bar, so very dark
                  // colours use the theme's text colour instead.
                  color: low ? root.urgent
                    : (root.realTonerColors && m.color ? root.visibleTonerColor(m.color) : Color.accent)
                  opacity: 0.85
                }
              }

              Text {
                id: tonerPct
                width: Style.space(36)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                textFormat: Text.PlainText
                text: known ? m.level + "%" : "—"
                color: low ? root.urgent : root.barForeground
                font.family: root.ff
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }

        PanelSeparator { visible: !!root.printer; foreground: root.barForeground }

        // ---------- Queue ----------
        Column {
          visible: !!root.printer
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: queueTitle.implicitHeight

            PanelSectionHeader {
              id: queueTitle
              text: "QUEUE"
              foreground: root.barForeground
              fontFamily: root.ff
            }

            PanelSectionHeader {
              anchors.right: parent.right
              visible: root.jobs.length > 0
              text: String(root.jobs.length)
              foreground: root.barForeground
              fontFamily: root.ff
            }
          }

          Text {
            visible: root.jobs.length === 0
            textFormat: Text.PlainText
            text: "Nothing waiting"
            color: root.dimForeground
            font.family: root.ff
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.jobs.length

            Item {
              required property int index
              readonly property var j: root.jobs[index] || ({})
              width: parent.width
              implicitHeight: Math.max(jobRow.implicitHeight, cancelButton.implicitHeight)

              InfoRow {
                id: jobRow
                anchors.left: parent.left
                anchors.right: cancelButton.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                icon: j.state === "printing" ? "\u{f042a}" : "\u{f0150}" // printer / clock
                key: j.mine ? j.name : "Another user's job"
                value: root.jobState(j)
                valueColor: j.state === "printing" ? root.barForeground : root.dimForeground
              }

              PanelActionButton {
                id: cancelButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: j.mine === true
                iconText: "\u{f0156}" // nf-md-close
                tooltipText: "Cancel"
                foreground: root.barForeground
                hoverColor: root.urgent
                fontFamily: root.ff
                fontSize: Style.font.bodySmall
                onClicked: root.cancelJob(j.id)
              }
            }
          }

          Button {
            visible: root.myJobs.length > 1
            width: parent.width
            text: "Cancel all my jobs"
            fontSize: Style.font.bodySmall
            foreground: root.barForeground
            fontFamily: root.ff
            bordered: true
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.cancelMine()
          }
        }

        PanelSeparator { visible: !!root.printer; foreground: root.barForeground }

        // ---------- Actions ----------
        Grid {
          visible: !!root.printer
          width: parent.width
          columns: 2
          columnSpacing: Style.space(6)
          rowSpacing: Style.space(6)

          readonly property real cellWidth: (width - columnSpacing) / 2

          Button {
            width: parent.cellWidth
            iconText: root.paused ? "\u{f040a}" : "\u{f03e4}" // play / pause
            iconSize: Style.font.icon
            text: root.paused ? "Resume" : "Pause"
            tooltipText: "Needs your password"
            fontSize: Style.font.bodySmall
            foreground: root.barForeground
            fontFamily: root.ff
            bordered: true
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
            onClicked: root.togglePause()
          }

          Button {
            width: parent.cellWidth
            iconText: "\u{f0219}" // nf-md-file
            iconSize: Style.font.icon
            text: root.testArmed ? "Click to print" : "Test page"
            fontSize: Style.font.bodySmall
            foreground: root.testArmed ? root.urgent : root.barForeground
            fontFamily: root.ff
            bordered: true
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
            onClicked: root.printTestPage()
          }

          Button {
            width: parent.cellWidth
            enabled: !!root.printer && root.printer.web !== ""
            iconText: "\u{f059f}" // nf-md-web
            iconSize: Style.font.icon
            text: "Web page"
            fontSize: Style.font.bodySmall
            foreground: root.barForeground
            fontFamily: root.ff
            bordered: true
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
            onClicked: root.openWeb()
          }

          Button {
            width: parent.cellWidth
            iconText: "\u{f0493}" // nf-md-cog
            iconSize: Style.font.icon
            text: "Settings"
            fontSize: Style.font.bodySmall
            foreground: root.barForeground
            fontFamily: root.ff
            bordered: true
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
            onClicked: root.openSettings()
          }
        }
      }
    }
  }
}
