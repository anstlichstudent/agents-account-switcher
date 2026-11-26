import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Panel {
  id: root
  moduleName: "agent-tools.account-switcher"
  ipcTarget: "agent-tools.account-switcher"
  manageIpc: false

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  readonly property string codexScript: decodeURIComponent(Qt.resolvedUrl("codex-account.py").toString().slice(7))
  readonly property string agyScript: decodeURIComponent(Qt.resolvedUrl("agy-account.py").toString().slice(7))
  readonly property string cacheScript: decodeURIComponent(Qt.resolvedUrl("account-cache.py").toString().slice(7))
  readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache")
    + "/omarchy/account-switcher"
  readonly property var providerCache: agySelected ? agyCache : codexCache
  readonly property string usageDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
    + "/omarchy/agents/usage"
  readonly property var modelRows: agySelected ? agyUsage.rows : codexUsage.rows

  AccountCache {
    id: codexCache
    provider: "codex"
  }

  AccountCache {
    id: agyCache
    provider: "agy"
  }

  UsageRecord {
    id: codexUsage
    path: root.usageDir + "/codex.json"
  }

  UsageRecord {
    id: agyUsage
    path: root.usageDir + "/agy.json"
  }

  property bool agySelected: false
  property string switchError: ""
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int refreshIntervalSec: Math.max(15, Number(setting("refreshIntervalSec", 60)) || 60)
  readonly property bool refreshInBackground: setting("refreshInBackground", true) !== false
  readonly property bool showAccountInBar: setting("showAccountInBar", true) !== false

  readonly property var accounts: providerCache.snapshot.accounts
  readonly property bool loading: providerCache.loading
  readonly property string errorMessage: providerCache.failed
    ? strings.t(providerCache.snapshot.updatedAt > 0 ? "error.stale" : "error.statusFailed") : ""
  property bool swapping: false
  property string swappingName: ""
  property int selectedIndex: 0
  property bool cursorActive: false

  property string swappingAccount: ""
  property string swapStderr: ""

  readonly property var activeAccount: {
    for (var i = 0; i < accounts.length; i++) {
      if (accounts[i] && accounts[i].active) return accounts[i]
    }
    return null
  }

  readonly property string activeShortName: {
    if (!activeAccount || !activeAccount.name) return ""
    var name = String(activeAccount.name)
    var at = name.indexOf("@")
    return at > 0 ? name.slice(0, at) : name
  }

  function plainText(value) {
    return String(value === undefined || value === null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
  }

  function modelUsageRows(content) {
    try {
      var buckets = JSON.parse(content).modelUsage || {}
      return Object.keys(buckets).map(function(id) {
        var bucket = buckets[id] || {}
        var total = Number(bucket.inputTokens || 0) + Number(bucket.outputTokens || 0)
          + Number(bucket.cacheReadInputTokens || 0) + Number(bucket.cacheCreationInputTokens || 0)
        var name = id.replace(/^claude-/, "").replace(/-\d{8}$/, "")
          .replace(/(\d)-(?=\d)/g, "$1.")
          .split("-").map(function(word) {
            if (word === "gpt") return "GPT"
            if (word === "deepseek") return "DeepSeek"
            return word.charAt(0).toUpperCase() + word.slice(1)
          }).join(" ")
        return { name: name, total: total }
      }).filter(function(row) {
        return isFinite(row.total) && row.total > 0
      }).sort(function(a, b) {
        return b.total - a.total
      }).slice(0, 4)
    } catch (error) {
      return []
    }
  }

  function formatTokenCount(value) {
    if (value >= 1e9) return (value / 1e9).toFixed(1) + "B"
    if (value >= 1e6) return (value / 1e6).toFixed(1) + "M"
    if (value >= 1e3) return (value / 1e3).toFixed(1) + "K"
    return String(value)
  }

  function formatReset(resetAt) {
    if (!resetAt) return ""
    var target = Date.parse(String(resetAt))
    if (isNaN(target)) return ""
    var diffSec = Math.floor((target - Date.now()) / 1000)
    if (diffSec <= 0) return strings.t("quota.resetSoon")
    var days = Math.floor(diffSec / 86400)
    var hours = Math.floor((diffSec % 86400) / 3600)
    var mins = Math.floor((diffSec % 3600) / 60)
    if (days > 0) return days + "d " + hours + "h"
    if (hours > 0) return hours + "h " + mins + "m"
    return Math.max(1, mins) + "m"
  }

  function quotaPercent(q) {
    if (!q || q.unlimited) return 0
    var total = Number(q.total || 0)
    var used = Number(q.used || 0)
    if (total <= 0) return 0
    return Math.max(0, Math.min(100, Math.round((used / total) * 100)))
  }

  function refresh(force) {
    if (!swapping) providerCache.refresh(force, "")
  }

  function selectProvider(agy) {
    if (swapping || agySelected === agy) return
    agySelected = agy
    selectedIndex = Math.max(0, accounts.findIndex(function(account) { return account.active }))
    cursorActive = false
    switchError = ""
    refresh(false)
  }

  function switchAccount(account) {
    if (!account || account.active || loading || swapping) return
    var name = String(account.name || "")
    if (name === "" || typeof account.id !== "string" || account.id === "") return
    switchError = ""
    swapping = true
    swappingName = name
    swappingAccount = account.id
    swapStderr = ""
    swapProc.command = agySelected
      ? ["/usr/bin/python3", agyScript, "--swap=" + swappingAccount]
      : ["/usr/bin/python3", codexScript, "--swap=" + swappingAccount]
    swapProc.running = true
  }

  function moveCursor(delta) {
    if (accounts.length === 0) return
    selectedIndex = Math.max(0, Math.min(accounts.length - 1, selectedIndex + delta))
  }

  function activateSelected() {
    if (selectedIndex < 0 || selectedIndex >= accounts.length) return
    switchAccount(accounts[selectedIndex])
  }

  function toggleBarLabel() {
    root.settings = Object.assign({}, root.settings, { showAccountInBar: !root.showAccountInBar })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  ShellIpc {
    target: "agent-tools.account-switcher"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh(true) }
  }

  onOpenedChanged: {
    if (opened) {
      refresh(false)
      cursorActive = false
      var activeIdx = 0
      for (var i = 0; i < accounts.length; i++) {
        if (accounts[i] && accounts[i].active) {
          activeIdx = i
          break
        }
      }
      selectedIndex = activeIdx
    }
  }

  Timer {
    interval: 5000
    running: root.opened || (root.refreshInBackground && !root.agySelected)
    repeat: true
    onTriggered: root.refresh(false)
  }

  onAccountsChanged: selectedIndex = Math.min(selectedIndex, Math.max(0, accounts.length - 1))

  Process {
    id: swapProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.swapStderr = text
    }
    onExited: function(exitCode) {
      root.swapping = false
      root.swappingName = ""
      if (exitCode === 0) {
        root.providerCache.markActive(root.swappingAccount)
        root.providerCache.refresh(true, root.swappingAccount)
      } else {
        var err = root.swapStderr.trim().slice(0, 240)
        root.switchError = root.agySelected && exitCode === 3
          ? strings.t("agy.closeFirst")
          : (err !== "" ? err : strings.t("error.swapFailed"))
      }
    }
  }

  FontMetrics {
    id: barLabelMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.bar.iconFont
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱚣"
    labelText: root.showAccountInBar && !vertical && root.activeShortName !== "" ? root.activeShortName : ""
    slotSize: !vertical && labelText !== ""
      ? Math.min(Style.space(150), Style.bar.iconSlot + barLabelMetrics.advanceWidth(labelText) + Style.space(10))
      : Style.bar.iconSlot
    tooltipText: root.activeAccount
      ? root.plainText(root.activeAccount.name + (root.activeAccount.plan ? " (" + root.activeAccount.plan + ")" : ""))
      : strings.t("bar.tooltip")
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleBarLabel()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(390))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      implicitHeight: mainColumn.implicitHeight

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.switchPanel(dx)
          return
        }
        if (!root.cursorActive) {
          root.cursorActive = true
          return
        }
        if (dy !== 0) root.moveCursor(dy)
      }

      onActivateRequested: root.activateSelected()
      onCloseRequested: root.close()

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_R) {
          root.refresh(true)
          event.accepted = true
        }
      }

      Text {
        y: providerTabs.y + providerTabs.height
        width: parent.width
        height: Math.max(0, mainColumn.implicitHeight - y)
        clip: true
        textFormat: Text.PlainText
        text: root.agySelected ? "\ue91c" : "\ue905"
        font.family: "omarchy"
        font.pixelSize: Math.max(1, Math.round(Math.min(width * 0.74, height * 0.84)))
        color: root.foreground
        opacity: 0.08
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        Accessible.ignored: true
      }

      Column {
        id: mainColumn
        width: parent.width
        spacing: Style.space(10)

        RowLayout {
          width: parent.width
          spacing: Style.space(8)

          PanelHero {
            Layout.fillWidth: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            title: strings.t("panel.title")
            meta: "9Router"
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "󱚣"
                color: Commons.Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Button {
            iconText: "󰑓"
            iconSpinning: root.loading
            tooltipText: strings.t("panel.refresh")
            enabled: !root.loading && !root.swapping
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.refresh(true)
          }
        }

        RowLayout {
          id: providerTabs
          width: parent.width
          spacing: Style.space(4)
          uniformCellSizes: true

          Button {
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            text: "Codex"
            selected: !root.agySelected
            enabled: !root.swapping
            bordered: true
            onClicked: root.selectProvider(false)
          }

          Button {
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            text: "AGY"
            selected: root.agySelected
            enabled: !root.swapping
            bordered: true
            onClicked: root.selectProvider(true)
          }
        }

        Text {
          visible: root.providerCache.snapshot.updatedAt > 0
          width: parent.width
          textFormat: Text.PlainText
          text: strings.t("panel.lastUpdated").arg(
            new Date(root.providerCache.snapshot.updatedAt).toLocaleString(Qt.locale(), Locale.ShortFormat))
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        BorderSurface {
          visible: root.switchError !== "" || root.errorMessage !== ""
          width: parent.width
          implicitHeight: errorText.implicitHeight + Style.space(16)
          radius: Style.cornerRadius
          color: Qt.rgba(Commons.Color.urgent.r, Commons.Color.urgent.g, Commons.Color.urgent.b, 0.14)
          borderSpec: Border.controlSpec("normal", Commons.Color.urgent, Commons.Color.urgent)

          Text {
            id: errorText
            anchors.fill: parent
            anchors.margins: Style.space(8)
            textFormat: Text.PlainText
            text: root.switchError || root.errorMessage
            color: Commons.Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        Text {
          visible: root.accounts.length === 0 && (root.loading || root.errorMessage === "")
          width: parent.width
          textFormat: Text.PlainText
          text: strings.t(root.loading ? "panel.loading" : (root.agySelected ? "agy.empty" : "panel.empty"))
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.accounts

            delegate: CursorSurface {
              id: rowSurface
              required property var modelData
              required property int index

              readonly property bool isActive: !!modelData.active
              readonly property bool isSwappingThis: root.swapping && root.swappingName === String(modelData.name || "")
              readonly property var sessionQuota: modelData.quotas ? modelData.quotas.session : null
              readonly property var weeklyQuota: modelData.quotas ? modelData.quotas.weekly : null

              width: parent.width
              implicitHeight: rowColumn.implicitHeight + Style.space(20)
              hasCursor: root.cursorActive && root.selectedIndex === index
              current: isActive
              bordered: true
              foreground: root.foreground
              accent: Commons.Color.accent

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: isActive ? Qt.ArrowCursor : Qt.PointingHandCursor
                onEntered: {
                  root.cursorActive = true
                  root.selectedIndex = rowSurface.index
                }
                onClicked: root.switchAccount(rowSurface.modelData)
              }

              Column {
                id: rowColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(10)
                spacing: Style.space(6)

                RowLayout {
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: String(rowSurface.modelData.name || "")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: rowSurface.isActive
                    elide: Text.ElideRight
                  }

                  BorderSurface {
                    visible: !!rowSurface.modelData.plan
                    implicitWidth: planText.implicitWidth + Style.space(10)
                    implicitHeight: planText.implicitHeight + Style.space(4)
                    radius: Style.cornerRadius
                    color: "transparent"
                    borderSpec: Border.controlSpec("normal", root.foreground, Commons.Color.accent)

                    Text {
                      id: planText
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: String(rowSurface.modelData.plan || "").toUpperCase()
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Rectangle {
                    id: resetBadge
                    readonly property var count: rowSurface.modelData.resetCreditsAvailable
                    readonly property bool hasCredits: count > 0
                    readonly property color ink: !hasCredits ? root.dim
                      : (root.foreground.r + root.foreground.g + root.foreground.b > 1.5 ? "#ff916c" : "#9b3b1e")
                    readonly property string label: visible ? strings.t("quota.resetCredits").arg(
                      Commons.I18n.formatNumber(count)) : ""
                    visible: !root.agySelected && typeof count === "number"
                    implicitWidth: resetLabel.implicitWidth + Style.space(10)
                    implicitHeight: resetLabel.implicitHeight + Style.space(4)
                    radius: Style.space(5)
                    border.width: 1
                    border.color: Qt.rgba(ink.r, ink.g, ink.b, hasCredits ? 0.34 : 0.24)
                    color: Qt.rgba(ink.r, ink.g, ink.b, hasCredits ? 0.08 : 0.04)

                    Accessible.role: Accessible.StaticText
                    Accessible.name: label

                    Row {
                      id: resetLabel
                      anchors.centerIn: parent
                      spacing: Style.space(4)

                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        textFormat: Text.PlainText
                        text: "󰑓"
                        color: resetBadge.ink
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        Accessible.ignored: true
                      }

                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        textFormat: Text.PlainText
                        text: resetBadge.visible ? Commons.I18n.formatNumber(resetBadge.count) : ""
                        color: resetBadge.ink
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        Accessible.ignored: true
                      }
                    }

                    MouseArea {
                      id: resetHover
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.ArrowCursor
                      onPressed: function(mouse) { mouse.accepted = true }
                    }

                    PanelToolTip {
                      visible: resetHover.containsMouse
                      text: resetBadge.label
                      fontFamily: root.fontFamily
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: rowSurface.isSwappingThis
                      ? strings.t("account.switching")
                      : (rowSurface.isActive ? strings.t("account.active") : strings.t("account.switch"))
                    color: rowSurface.isActive ? Commons.Color.accent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: rowSurface.isActive
                  }
                }

                RowLayout {
                  visible: !!rowSurface.sessionQuota || !!rowSurface.weeklyQuota
                  width: parent.width
                  spacing: Style.space(16)
                  uniformCellSizes: true

                  QuotaMeter {
                    Layout.fillWidth: true
                    visible: !!quota
                    label: strings.t(root.agySelected ? "quota.geminiSession" : "quota.session")
                    quota: rowSurface.sessionQuota
                  }

                  QuotaMeter {
                    Layout.fillWidth: true
                    visible: !!quota
                    label: strings.t(root.agySelected ? "quota.geminiWeekly" : "quota.weekly")
                    quota: rowSurface.weeklyQuota
                  }
                }
              }
            }
          }
        }

        PanelSeparator {
          visible: root.modelRows.length > 0
          width: parent.width
          foreground: root.foreground
        }

        Column {
          visible: root.modelRows.length > 0
          width: parent.width
          spacing: Style.space(5)

          PanelSectionHeader {
            width: parent.width
            text: strings.t("usage.tokensByModel")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.modelRows

            delegate: Rectangle {
              id: modelRow
              required property var modelData
              width: parent.width
              implicitHeight: modelLabels.implicitHeight + Style.space(8)
              radius: Style.cornerRadius
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)

              Rectangle {
                width: parent.width * modelRow.modelData.total / root.modelRows[0].total
                height: parent.height
                radius: parent.radius
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
              }

              RowLayout {
                id: modelLabels
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: modelRow.modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.formatTokenCount(modelRow.modelData.total)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
              }
            }
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          visible: text !== root.switchError
          text: strings.t(root.agySelected ? "agy.closeFirst" : "panel.hint")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  component AccountCache: FileView {
    id: cache
    required property string provider
    property var snapshot: ({ accounts: [], updatedAt: 0 })
    property bool ready: false
    property bool failed: false
    property double lastAttempt: 0
    readonly property bool loading: fetchStatus.running
    path: root.cacheDir + "/" + provider + ".json"
    watchChanges: true
    printErrors: false

    function refresh(force, active) {
      if (!ready || loading) return
      var now = Date.now()
      var lastRead = Math.max(snapshot.updatedAt, lastAttempt)
      if (!force && now >= lastRead && now - lastRead < root.refreshIntervalSec * 1000) return
      lastAttempt = now
      fetchStatus.command = ["/usr/bin/python3", root.cacheScript, provider,
                             "--max-age", force ? "0" : String(root.refreshIntervalSec)]
      if (active !== "") fetchStatus.command = fetchStatus.command.concat(["--active=" + active])
      fetchStatus.running = true
    }

    function markActive(identifier) {
      snapshot = {
        updatedAt: snapshot.updatedAt,
        accounts: snapshot.accounts.map(function(account) {
          return Object.assign({}, account, { active: account.id === identifier })
        })
      }
    }

    function finishInitialRead() {
      if (ready) return
      ready = true
      if (root.opened || root.refreshInBackground) refresh(false, "")
    }

    onLoaded: {
      try {
        var data = JSON.parse(text())
        if (Array.isArray(data.accounts) && typeof data.updatedAt === "number"
            && data.accounts.every(function(account) { return account && typeof account.name === "string" })) {
          snapshot = data.accounts.some(function(account) { return typeof account.id !== "string" })
            ? { accounts: data.accounts, updatedAt: 0 } : data
        }
      } catch (error) {}
      finishInitialRead()
    }
    onLoadFailed: finishInitialRead()
    onFileChanged: reload()

    property Process fetchStatus: Process {
      onExited: function(exitCode) {
        cache.failed = exitCode !== 0
        cache.reload()
      }
    }
  }

  component UsageRecord: FileView {
    property var rows: []
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: rows = root.modelUsageRows(text())
    onLoadFailed: rows = []
  }

  component QuotaMeter: ColumnLayout {
    id: meter
    required property string label
    required property var quota
    readonly property real used: root.quotaPercent(quota)
    readonly property string reset: root.formatReset(quota ? quota.resetAt : "")
    spacing: Style.space(4)

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(5)

      Text {
        textFormat: Text.PlainText
        text: meter.label
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: meter.quota && meter.quota.unlimited
          ? strings.t("quota.unlimited")
          : Commons.I18n.formatNumber(meter.used) + "%"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(5)

      Rectangle {
        Layout.fillWidth: true
        implicitHeight: Style.space(4)
        radius: height / 2
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

        Rectangle {
          width: parent.width * meter.used / 100
          height: parent.height
          radius: parent.radius
          color: meter.used >= 85 ? Commons.Color.urgent : Commons.Color.accent
        }
      }

      Text {
        visible: meter.reset !== ""
        textFormat: Text.PlainText
        text: meter.reset
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
