#pragma once
#include <plasma/containmentactions.h>

class QAction;

// A ContainmentActions plugin that steps one virtual desktop when its mouse
// trigger fires. It returns exactly ONE contextual action, which is what
// makes ContainmentItem::mousePressEvent run it directly instead of opening
// a menu -- the stock org.kde.switchdesktop returns one action per desktop
// and therefore always pops a menu on a button press.
class StepDesktop : public Plasma::ContainmentActions
{
    Q_OBJECT
public:
    explicit StepDesktop(QObject *parent, const QVariantList &args);
    QList<QAction *> contextualActions() override;
    void performNextAction() override;
    void performPreviousAction() override;

private:
    void step();
    QAction *m_action;
};
