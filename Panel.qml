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

  function choice(name, options, fallback) {
    var v = settings ? String(settings[name] === undefined || settings[name] === null ? "" : settings[name]) : ""
    return options.indexOf(v) >= 0 ? v : fallback
  }
  readonly property string scanSource: choice("scanSource", ["auto", "platen", "feeder"], "auto")
  readonly property string scanColor: choice("scanColor", ["color", "gray", "bw"], "color")
  readonly property string scanDpi: choice("scanDpi", ["100", "200", "300", "600"], "300")
  readonly property string scanSize: choice("scanSize", ["a4", "letter", "legal", "max"], "a4")
  readonly property string scanFormat: choice("scanFormat", ["pdf", "jpeg"], "pdf")
  readonly property bool scanOpen: boolSetting("scanOpen", false)

  // Saved to this widget's shell.json entry through the shell's own API, as
  // the stock clock and Tailscale panels save theirs.
  function saveSetting(key, value) {
    var entry = { id: moduleName }
    for (var k in settings) if (k !== "id") entry[k] = settings[k]
    entry[key] = value
    settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, entry)
  }

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
  readonly property bool paused: !!printer && printer.status === "Paused"
  readonly property bool offline: !!printer && printer.status === "Offline"

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
  // Commands run with fixed argv and absolute paths (no shell, no PATH
  // lookup); the feed is refreshed after each.
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
    if (/^[0-9]{1,9}$/.test(String(id))) run(["/usr/bin/cancel", String(id)])
  }

  function cancelMine() {
    var ids = myJobs.map(function(j) { return String(j.id) }).filter(function(id) { return /^[0-9]{1,9}$/.test(id) })
    if (ids.length) run(["/usr/bin/cancel"].concat(ids))
  }

  // Pausing needs admin rights in CUPS; pkexec shows the shell's password prompt.
  function togglePause() {
    if (!safeName) return
    close()
    run(["/usr/bin/pkexec", paused ? "/usr/bin/cupsenable" : "/usr/bin/cupsdisable", safeName])
  }

  property bool testArmed: false
  Timer { id: disarm; interval: 3000; onTriggered: root.testArmed = false }
  function printTestPage() {
    if (!safeName) return
    if (!testArmed) { testArmed = true; disarm.restart(); return }
    testArmed = false
    // The PDF itself, not CUPS's "testprint" banner: on cups-filters 2.x the
    // banner's bannertopdf -> pdftopdf step can fail ("universal filter
    // failed") while plain PDFs print fine.
    run(["/usr/bin/lp", "-d", safeName, "-t", "Test page", "/usr/share/cups/data/default-testpage.pdf"])
  }

  function openWeb() {
    if (printer && /^https?:\/\/[A-Za-z0-9.-]+\/$/.test(printer.web)) {
      Quickshell.execDetached(["/usr/bin/xdg-open", printer.web])
      close()
    }
  }

  function openSettings() {
    Quickshell.execDetached(["/usr/bin/uwsm-app", "--", "/usr/bin/system-config-printer"])
    close()
  }

  // ---------- Scanning ----------
  // bin/omarchy-printer-scan runs only while a scan is in progress and exits
  // when it is done; it prints its progress as JSON lines.
  property string tab: "printer"
  readonly property var scanner: printer ? printer.scanner || null : null
  readonly property bool canScan: !!scanner && /^https?:\/\/[A-Za-z0-9.-]+:[0-9]{1,5}\/[A-Za-z0-9_-]{1,32}$/.test(scanner.url)
  onCanScanChanged: if (!canScan && !scanning) tab = "printer"

  property bool scanning: scanProc.running
  property string scanStep: ""
  property string scanError: ""
  property var lastScan: []          // files of the last finished scan
  property string lastScanDir: ""

  readonly property var sourceOptions: {
    var out = [{ value: "auto", label: "Auto" }, { value: "platen", label: "Glass" }]
    if (scanner && scanner.sources.indexOf("adf") >= 0) out.push({ value: "feeder", label: "Feeder" })
    return out
  }
  readonly property var colorOptions: {
    var out = [{ value: "color", label: "Colour" }, { value: "gray", label: "Grey" }]
    // 1-bit has no JPEG form, so black and white is a PDF-only choice.
    if (scanner && scanner.colors.indexOf("binary") >= 0 && scanFormat === "pdf") out.push({ value: "bw", label: "B&W" })
    return out
  }
  readonly property var dpiOptions: [
    { value: "100", label: "100" }, { value: "200", label: "200" },
    { value: "300", label: "300" }, { value: "600", label: "600" }
  ]
  readonly property var sizeOptions: [
    { value: "a4", label: "A4" }, { value: "letter", label: "Letter" },
    { value: "legal", label: "Legal" }, { value: "max", label: "Max" }
  ]
  readonly property var formatOptions: {
    var out = []
    if (!scanner || scanner.formats.indexOf("application/pdf") >= 0) out.push({ value: "pdf", label: "PDF" })
    if (!scanner || scanner.formats.indexOf("image/jpeg") >= 0) out.push({ value: "jpeg", label: "JPEG" })
    return out
  }

  Process {
    id: scanProc
    running: false
    command: []
    stdout: SplitParser {
      onRead: function(line) {
        if (line.length > 65536) return
        var d
        try { d = JSON.parse(String(line)) } catch (e) { return }
        if (!d || typeof d !== "object") return
        if (d.state === "starting") root.scanStep = d.source === "feeder" ? "Feeding pages…" : "Scanning…"
        else if (d.state === "scanning") root.scanStep = "Scanning page " + Number(d.page || 1) + "…"
        else if (d.state === "error") root.scanError = String(d.message || "Scan failed").substring(0, 80)
        else if (d.state === "done" && Array.isArray(d.files)) {
          root.lastScan = d.files.filter(function(f) { return typeof f === "string" && f.charAt(0) === "/" }).slice(0, 60)
          root.lastScanDir = typeof d.dir === "string" && d.dir.charAt(0) === "/" ? d.dir : ""
          if (root.scanOpen && root.lastScan.length) root.openPath(root.lastScan[0])
        }
      }
    }
    onExited: root.scanStep = ""
  }

  function startScan() {
    if (!canScan || scanning) return
    scanError = ""
    scanStep = "Starting…"
    var color = scanColor === "bw" && scanFormat !== "pdf" ? "gray" : scanColor
    var cmd = [pluginDir + "bin/omarchy-printer-scan",
      "--url", scanner.url, "--source", scanSource, "--color", color, "--dpi", scanDpi,
      "--size", scanSize, "--format", scanFormat, "--name", printer.info]
      .concat(notifications ? [] : ["--no-notify"])
    if (scanner.fallback)
      cmd.push("--fallback-url", scanner.fallback)
    scanProc.command = cmd
    scanProc.running = true
  }

  // Stopping the process sends it SIGTERM, which cancels the job on the
  // scanner and removes the half-written file.
  function cancelScan() {
    if (scanning) scanProc.running = false
  }

  function openPath(path) {
    if (typeof path === "string" && path.charAt(0) === "/")
      Quickshell.execDetached(["/usr/bin/xdg-open", path])
  }

  function fileName(path) {
    return String(path || "").replace(/^.*\//, "")
  }

  // ---------- Keyboard cursor ----------
  // Everything you can act on, top to bottom, as the stock panels do:
  // arrows or h/j/k/l move, Enter or Space acts, x cancels the job under the
  // cursor, r refreshes. The four action buttons form a 2x2 grid.
  property bool cursorActive: false
  property int cursorIndex: 0

  readonly property var scanRows: ["source", "color", "dpi", "size", "format", "open"]

  readonly property var focusItems: {
    var out = []
    if (printers.length > 1)
      for (var i = 0; i < printers.length; i++) out.push("pick:" + i)
    if (canScan) out.push("tabs")
    if (tab === "scan" && canScan) {
      for (var r = 0; r < scanRows.length; r++) out.push("scan:" + scanRows[r])
      out.push("scan:go")
      if (lastScan.length) out.push("scan:file", "scan:folder")
      return out
    }
    for (var j = 0; j < jobs.length; j++)
      if (jobs[j].mine) out.push("job:" + jobs[j].id)
    if (myJobs.length > 1) out.push("cancelAll")
    if (printer) {
      out.push("pause", "test")
      out.push(printer.web !== "" ? "web" : "web-off", "settings")
    }
    return out
  }
  readonly property string cursorItem: cursorActive && cursorIndex < focusItems.length ? focusItems[cursorIndex] : ""
  onFocusItemsChanged: if (cursorIndex >= focusItems.length) cursorIndex = Math.max(0, focusItems.length - 1)

  function hasCursor(key) { return cursorItem === key }

  function stepOption(key, options, current, dx) {
    var values = options.map(function(o) { return o.value })
    var i = values.indexOf(current)
    var n = values.length
    if (n) saveSetting(key, values[((i < 0 ? 0 : i) + dx + n) % n])
  }

  function moveCursor(dx, dy) {
    var items = focusItems
    if (!items.length) return
    if (!cursorActive) { cursorActive = true; cursorIndex = 0; return }
    var here = items[cursorIndex] || ""
    // Left/right on the tab row switches tabs; on a scan option, changes it.
    if (dx !== 0 && here === "tabs") { tab = dx > 0 ? "scan" : "printer"; return }
    if (dx !== 0 && here.indexOf("scan:") === 0) {
      var row = here.substring(5)
      if (row === "source") stepOption("scanSource", sourceOptions, scanSource, dx)
      else if (row === "color") stepOption("scanColor", colorOptions, scanColor, dx)
      else if (row === "dpi") stepOption("scanDpi", dpiOptions, scanDpi, dx)
      else if (row === "size") stepOption("scanSize", sizeOptions, scanSize, dx)
      else if (row === "format") stepOption("scanFormat", formatOptions, scanFormat, dx)
      else if (row === "open") saveSetting("scanOpen", dx > 0)
      else if (row === "file" || row === "folder") cursorIndex = items.indexOf(row === "file" ? "scan:folder" : "scan:file")
      return
    }
    if (tab === "scan") {
      cursorIndex = Math.max(0, Math.min(items.length - 1, cursorIndex + (dy !== 0 ? dy : dx)))
      return
    }
    var grid = items.indexOf("pause")
    var i = cursorIndex
    var t
    if (grid >= 0 && i >= grid) {
      // In the 2x2 grid: left/right within a row, up/down between rows.
      var col = (i - grid) % 2, row = Math.floor((i - grid) / 2)
      if (dx !== 0) t = grid + row * 2 + Math.max(0, Math.min(1, col + dx))
      else if (row + dy < 0) t = grid - 1
      else t = grid + Math.min(1, row + dy) * 2 + col
    } else {
      t = i + (dy !== 0 ? dy : dx)
    }
    if (t < 0) t = 0
    if (t >= items.length) t = items.length - 1
    if (items[t] === "web-off") t = t + (t > i ? 1 : -1)
    cursorIndex = Math.max(0, Math.min(items.length - 1, t))
  }

  function activate(key) {
    if (key.indexOf("pick:") === 0) {
      var p = printers[parseInt(key.substring(5), 10)]
      if (p) chosenName = p.name
    } else if (key.indexOf("job:") === 0) {
      cancelJob(key.substring(4))
    } else if (key === "tabs") tab = tab === "scan" ? "printer" : "scan"
    else if (key === "scan:open") saveSetting("scanOpen", !scanOpen)
    else if (key === "scan:go") scanning ? cancelScan() : startScan()
    else if (key === "scan:file") openPath(lastScan[0])
    else if (key === "scan:folder") openPath(lastScanDir)
    else if (key.indexOf("scan:") === 0) moveCursor(1, 0)
    else if (key === "cancelAll") cancelMine()
    else if (key === "pause") togglePause()
    else if (key === "test") printTestPage()
    else if (key === "web") openWeb()
    else if (key === "settings") openSettings()
  }

  onOpenedChanged: if (opened) { testArmed = false; cursorActive = false; cursorIndex = 0; refresh() }
  onTabChanged: { cursorIndex = Math.max(0, focusItems.indexOf("tabs")); testArmed = false }

  // ---------- Bar icon ----------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // printer / printer-off (nf-md)
    // scanner while a scan runs; printer-off when there is no printer or it
    // is offline; the hollow printer-outline when it is paused; else printer
    text: root.scanning ? "\u{f06ab}"
      : !root.printer || root.offline ? "\u{f0e5d}"
      : root.paused ? "\u{f1786}" : "\u{f042a}"
    active: root.hasProblem
    dimmed: !root.printer || root.paused || root.offline
    tooltipText: root.scanning ? root.scanStep
      : !root.printer ? "No printer"
      : root.printer.info + " · " + (root.hasProblem ? root.printer.problems[0]
          : root.paused ? "Paused, press Resume to print" : root.printer.status)
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

  // A scan option: its label on the left, its choices on the right.
  component OptionRow: Item {
    id: optionRow
    property string label: ""
    property var options: []
    property string value: ""
    property bool hasCursor: false
    signal picked(string value)

    width: parent ? parent.width : 0
    implicitHeight: Math.max(optionLabel.implicitHeight, choices.implicitHeight)

    Text {
      id: optionLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: optionRow.label
      color: root.dimForeground
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
    }

    ButtonGroup {
      id: choices
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      options: optionRow.options
      value: optionRow.value
      foreground: root.barForeground
      fontFamily: root.ff
      fontSize: Style.font.caption
      focusable: false
      cursorIndex: optionRow.hasCursor
        ? optionRow.options.map(function(o) { return o.value }).indexOf(optionRow.value) : -1
      onChanged: function(v) { optionRow.picked(v) }
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
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: if (root.cursorItem !== "") root.activate(root.cursorItem)
      onDeleteRequested: if (root.cursorItem.indexOf("job:") === 0) root.activate(root.cursorItem)
      onTextKey: function(t) { if (t === "r" || t === "R") root.refresh() }

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

        // ---------- Printer list (more than one printer) ----------
        // One full-width row per printer with its status; the chosen one is
        // highlighted. Printers sharing a name are told apart by queue name.
        Column {
          visible: root.printers.length > 1
          width: parent.width
          spacing: Style.space(4)

          PanelSectionHeader {
            text: "PRINTERS"
            foreground: root.barForeground
            fontFamily: root.ff
          }

          Repeater {
            model: root.printers.length
            Button {
              required property int index
              readonly property var p: root.printers[index] || ({})
              readonly property bool twin: root.printers.some(function(o, i) { return i !== index && o.info === p.info })
              width: parent.width
              leftAlign: true
              iconText: p.status === "Offline" ? "\u{f0e5d}" : p.status === "Paused" ? "\u{f1786}" : "\u{f042a}"
              iconSize: Style.font.icon
              text: (p.info || "") + (twin ? " (" + p.name + ")" : "") + "  ·  " + (p.status || "")
              fontSize: Style.font.bodySmall
              fontFamily: root.ff
              foreground: root.barForeground
              selected: !!root.printer && p.name === root.printer.name
              hasCursor: root.hasCursor("pick:" + index)
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.chosenName = p.name
            }
          }
        }

        // ---------- Tabs (only for a printer with a scanner) ----------
        Row {
          visible: root.canScan
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: [{ key: "printer", label: "Printer", icon: "\u{f042a}" }, { key: "scan", label: "Scan", icon: "\u{f06ab}" }]
            Button {
              required property var modelData
              width: (parent.width - parent.spacing) / 2
              iconText: modelData.icon
              iconSize: Style.font.icon
              text: modelData.label
              selected: root.tab === modelData.key
              hasCursor: root.hasCursor("tabs") && root.tab === modelData.key
              fontSize: Style.font.bodySmall
              foreground: root.barForeground
              fontFamily: root.ff
              bordered: true
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.tab = modelData.key
            }
          }
        }

        // ---------- Printer tab ----------
        Column {
          visible: root.tab === "printer" || !root.canScan
          width: parent.width
          spacing: Style.space(14)

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
                  : root.printer.status + (root.printer.message && root.printer.message !== root.printer.status
                    ? " · " + root.printer.message : "")
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
                  hasCursor: root.hasCursor("job:" + j.id)
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
              hasCursor: root.hasCursor("cancelAll")
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
              hasCursor: root.hasCursor("pause")
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
              text: root.testArmed ? "Again to print" : "Test page"
              hasCursor: root.hasCursor("test")
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
              hasCursor: root.hasCursor("web")
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
              hasCursor: root.hasCursor("settings")
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

        // ---------- Scan tab ----------
        Column {
          visible: root.tab === "scan" && root.canScan
          width: parent.width
          spacing: Style.space(12)

          Item {
            width: parent.width
            implicitHeight: scanHead.implicitHeight

            Column {
              id: scanHead
              anchors.left: parent.left
              anchors.right: parent.right
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
                text: root.scanning ? root.scanStep
                  : root.scanError !== "" ? root.scanError
                  : root.offline ? "Offline"
                  : root.scanSource === "auto" ? "Auto uses the feeder when paper is in it"
                  : "Ready"
                color: root.scanError !== "" && !root.scanning ? root.urgent : root.dimForeground
                font.family: root.ff
                font.pixelSize: Style.font.caption
              }
            }
          }

          PanelSeparator { foreground: root.barForeground }

          OptionRow {
            label: "Source"
            options: root.sourceOptions
            value: root.scanSource
            hasCursor: root.hasCursor("scan:source")
            onPicked: function(v) { root.saveSetting("scanSource", v) }
          }

          OptionRow {
            label: "Colour"
            options: root.colorOptions
            value: root.scanColor === "bw" && root.scanFormat !== "pdf" ? "gray" : root.scanColor
            hasCursor: root.hasCursor("scan:color")
            onPicked: function(v) { root.saveSetting("scanColor", v) }
          }

          OptionRow {
            label: "Quality (dpi)"
            options: root.dpiOptions
            value: root.scanDpi
            hasCursor: root.hasCursor("scan:dpi")
            onPicked: function(v) { root.saveSetting("scanDpi", v) }
          }

          OptionRow {
            label: "Page size"
            options: root.sizeOptions
            value: root.scanSize
            hasCursor: root.hasCursor("scan:size")
            onPicked: function(v) { root.saveSetting("scanSize", v) }
          }

          OptionRow {
            label: "Format"
            options: root.formatOptions
            value: root.scanFormat
            hasCursor: root.hasCursor("scan:format")
            onPicked: function(v) { root.saveSetting("scanFormat", v) }
          }

          Item {
            width: parent.width
            implicitHeight: Math.max(openLabel.implicitHeight, openSwitch.implicitHeight)

            Text {
              id: openLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "Open the file after scanning"
              color: root.dimForeground
              font.family: root.ff
              font.pixelSize: Style.font.bodySmall
            }

            ToggleSwitch {
              id: openSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.scanOpen
              foreground: root.barForeground
              hasCursor: root.hasCursor("scan:open")
              onToggled: root.saveSetting("scanOpen", !root.scanOpen)
            }
          }

          Button {
            width: parent.width
            enabled: root.scanning || !root.offline
            iconText: root.scanning ? "\u{f0156}" : "\u{f06ab}" // close / scanner
            iconSize: Style.font.icon
            text: root.scanning ? "Cancel scan" : "Scan"
            hasCursor: root.hasCursor("scan:go")
            fontSize: Style.font.bodySmall
            foreground: root.scanning ? root.urgent : root.barForeground
            fontFamily: root.ff
            bordered: true
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY + Style.space(4)
            onClicked: root.scanning ? root.cancelScan() : root.startScan()
          }

          PanelSeparator { visible: root.lastScan.length > 0; foreground: root.barForeground }

          // ---------- Last scan ----------
          Column {
            visible: root.lastScan.length > 0
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: lastTitle.implicitHeight

              PanelSectionHeader {
                id: lastTitle
                text: "LAST SCAN"
                foreground: root.barForeground
                fontFamily: root.ff
              }

              PanelSectionHeader {
                anchors.right: parent.right
                visible: root.lastScan.length > 1
                text: root.lastScan.length + " FILES"
                foreground: root.barForeground
                fontFamily: root.ff
              }
            }

            InfoRow {
              icon: root.scanFormat === "jpeg" ? "\u{f021f}" : "\u{f0226}" // image / pdf
              key: root.fileName(root.lastScan[0])
              value: ""
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              Button {
                width: (parent.width - parent.spacing) / 2
                iconText: "\u{f0214}" // file
                iconSize: Style.font.icon
                text: "Open"
                hasCursor: root.hasCursor("scan:file")
                fontSize: Style.font.bodySmall
                foreground: root.barForeground
                fontFamily: root.ff
                bordered: true
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                onClicked: root.openPath(root.lastScan[0])
              }

              Button {
                width: (parent.width - parent.spacing) / 2
                iconText: "\u{f024b}" // folder
                iconSize: Style.font.icon
                text: "Folder"
                hasCursor: root.hasCursor("scan:folder")
                fontSize: Style.font.bodySmall
                foreground: root.barForeground
                fontFamily: root.ff
                bordered: true
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                onClicked: root.openPath(root.lastScanDir)
              }
            }
          }
        }
      }
    }
  }
}
