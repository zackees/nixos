#include "step.h"

#include <KConfigGroup>
#include <KPluginFactory>
#include <KSharedConfig>
#include <QAction>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCall>
#include <QProcess>

namespace {
// How long after a step the mouse back/forward buttons keep stepping
// desktops no matter what is under the pointer.
constexpr int kWindowMs = 2000;
const char *const kClearUnit = "stepdesktop-rebind-clear";

// The key sequence KWin has bound to a desktop-switch shortcut, read from
// kglobalshortcutsrc so a rebinding in System Settings is honoured.
QString shortcutKeys(const QString &name, const QString &fallback)
{
    auto cfg = KSharedConfig::openConfig(QStringLiteral("kglobalshortcutsrc"));
    const QString raw = cfg->group(QStringLiteral("kwin")).readEntry(name, QString());
    const QString first = raw.section(QLatin1Char(','), 0, 0).section(QLatin1Char('\t'), 0, 0);
    if (first.isEmpty() || first == QLatin1String("none")) {
        return fallback;
    }
    return first;
}
} // namespace

StepDesktop::StepDesktop(QObject *parent, const QVariantList &args)
    : Plasma::ContainmentActions(parent, args)
    , m_action(new QAction(this))
{
    connect(m_action, &QAction::triggered, this, &StepDesktop::step);
    // Any desktop change while the window is open keeps it open, so a run
    // of presses does not have to beat the clock -- including presses that
    // KWin turned into key events, which never come back through here.
    QDBusConnection::sessionBus().connect(QStringLiteral("org.kde.KWin"),
                                          QStringLiteral("/VirtualDesktopManager"),
                                          QStringLiteral("org.kde.KWin.VirtualDesktopManager"),
                                          QStringLiteral("currentChanged"),
                                          this,
                                          SLOT(onDesktopChanged()));
}

QList<QAction *> StepDesktop::contextualActions()
{
    return {m_action};
}

// Fire KWin's own "Switch One Desktop to the Left/Right" through
// kglobalaccel, the same call the panel's Desktops button makes for
// Overview. Going through KWin's shortcut rather than the desktop D-Bus API
// keeps two behaviours for free: with per-screen virtual desktops it acts
// on the screen that was clicked, and it honours kwinrc's RollOverDesktops,
// which is what turns wrap-around off.
void StepDesktop::step()
{
    auto msg = QDBusMessage::createMethodCall(QStringLiteral("org.kde.kglobalaccel"),
                                              QStringLiteral("/component/kwin"),
                                              QStringLiteral("org.kde.kglobalaccel.Component"),
                                              QStringLiteral("invokeShortcut"));
    msg << QString::fromUtf8(STEP_SHORTCUT);
    QDBusConnection::sessionBus().asyncCall(msg);
    arm();
}

// After a step the pointer usually lands on a window of the new desktop,
// and the next back/forward press would go to that window (a browser
// navigates). So for a short window the buttons are rebound compositor-wide
// to the desktop-switch key sequences, using KWin's own button-rebinding
// input filter: it reads kcminputrc [ButtonRebinds][Mouse] and reloads on
// change through KConfigWatcher, so a write with Notify takes effect at
// once. The rebind is cleared by a transient systemd user timer rather
// than from here, so a plasmashell crash cannot leave the browser's
// back/forward buttons hijacked for good.
void StepDesktop::arm()
{
    const QString left = shortcutKeys(QStringLiteral("Switch One Desktop to the Left"), QStringLiteral("Meta+Ctrl+Left"));
    const QString right = shortcutKeys(QStringLiteral("Switch One Desktop to the Right"), QStringLiteral("Meta+Ctrl+Right"));

    auto cfg = KSharedConfig::openConfig(QStringLiteral("kcminputrc"));
    KConfigGroup mouse = cfg->group(QStringLiteral("ButtonRebinds")).group(QStringLiteral("Mouse"));
    mouse.writeEntry(QStringLiteral("BackButton"), QStringList{QStringLiteral("Key"), left}, KConfig::Notify);
    mouse.writeEntry(QStringLiteral("ForwardButton"), QStringList{QStringLiteral("Key"), right}, KConfig::Notify);
    cfg->sync();
    m_armed.start();

    const QString clear = QStringLiteral(
        "/run/current-system/sw/bin/kwriteconfig6 --file kcminputrc --group ButtonRebinds --group Mouse --key BackButton --delete --notify; "
        "/run/current-system/sw/bin/kwriteconfig6 --file kcminputrc --group ButtonRebinds --group Mouse --key ForwardButton --delete --notify");
    QProcess stop;
    stop.setStandardErrorFile(QProcess::nullDevice());
    stop.start(QStringLiteral("systemctl"), {QStringLiteral("--user"), QStringLiteral("stop"), QStringLiteral("%1.timer").arg(kClearUnit), QStringLiteral("%1.service").arg(kClearUnit)});
    stop.waitForFinished(3000);
    QProcess run;
    run.setStandardErrorFile(QProcess::nullDevice());
    run.start(QStringLiteral("systemd-run"),
              {QStringLiteral("--user"), QStringLiteral("--quiet"), QStringLiteral("--collect"),
               QStringLiteral("--unit=%1").arg(kClearUnit),
               QStringLiteral("--on-active=%1ms").arg(kWindowMs),
               QStringLiteral("--timer-property=AccuracySec=50ms"),
               QStringLiteral("/bin/sh"), QStringLiteral("-c"), clear});
    run.waitForFinished(3000);
}

void StepDesktop::onDesktopChanged()
{
    if (m_armed.isValid() && m_armed.elapsed() < kWindowMs) {
        arm();
    }
}

void StepDesktop::performNextAction() { step(); }
void StepDesktop::performPreviousAction() { step(); }

K_PLUGIN_CLASS_WITH_JSON(StepDesktop, STEP_JSON)

#include "step.moc"
#include "moc_step.cpp"
