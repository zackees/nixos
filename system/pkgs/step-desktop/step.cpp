#include "step.h"

#include <KPluginFactory>
#include <QAction>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCall>

StepDesktop::StepDesktop(QObject *parent, const QVariantList &args)
    : Plasma::ContainmentActions(parent, args)
    , m_action(new QAction(this))
{
    connect(m_action, &QAction::triggered, this, &StepDesktop::step);
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
}

void StepDesktop::performNextAction() { step(); }
void StepDesktop::performPreviousAction() { step(); }

K_PLUGIN_CLASS_WITH_JSON(StepDesktop, STEP_JSON)

#include "step.moc"
#include "moc_step.cpp"
