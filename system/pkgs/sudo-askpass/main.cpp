// A sudo askpass helper with a choice of how long the ticket should last.
//
// sudo runs this with the prompt as argv[1] and reads the password from
// stdout. It has no way to hear anything else back, so the duration is
// enforced from here instead: sudoers grants the longest option (4 h) and
// the shorter ones schedule `sudo -k` on a transient systemd user timer.
// One timer unit, replaced on every use, so the latest choice always wins.
#include <QApplication>
#include <QDialog>
#include <QDialogButtonBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QProcess>
#include <QRadioButton>
#include <QSettings>
#include <QStyle>
#include <QTextStream>
#include <QVBoxLayout>

#include <sys/resource.h>

namespace {
const char *const kUnit = "sudo-ticket-expire";

struct Choice {
    const char *label;
    int seconds; // 0 = leave sudo's own timeout in charge
};
const Choice kChoices[] = {
    {"One time", 5},
    {"15 minutes", 15 * 60},
    {"4 hours", 0},
};

// Run a command to completion with its output discarded: sudo shows our
// stderr to the user, and "unit not loaded" from a stop of a timer that
// has already fired is noise, not news.
void run(const QString &program, const QStringList &args)
{
    QProcess p;
    p.setStandardOutputFile(QProcess::nullDevice());
    p.setStandardErrorFile(QProcess::nullDevice());
    p.start(program, args);
    p.waitForFinished(5000);
}

void schedule(int seconds)
{
    // Drop whatever the previous authentication scheduled.
    run(QStringLiteral("systemctl"),
        {QStringLiteral("--user"), QStringLiteral("stop"),
         QStringLiteral("%1.timer").arg(kUnit), QStringLiteral("%1.service").arg(kUnit)});
    run(QStringLiteral("systemctl"),
        {QStringLiteral("--user"), QStringLiteral("reset-failed"),
         QStringLiteral("%1.timer").arg(kUnit), QStringLiteral("%1.service").arg(kUnit)});
    if (seconds <= 0) {
        return;
    }
    run(QStringLiteral("systemd-run"),
                      {QStringLiteral("--user"), QStringLiteral("--quiet"), QStringLiteral("--collect"),
                       QStringLiteral("--unit=%1").arg(kUnit),
                       QStringLiteral("--on-active=%1").arg(seconds),
                       QStringLiteral("--timer-property=AccuracySec=1s"),
                       QStringLiteral("/run/wrappers/bin/sudo"), QStringLiteral("-k")});
}
} // namespace

int main(int argc, char **argv)
{
    // The dialog holds the password in memory; make sure a crash cannot
    // write it to a core file. Same precaution ksshaskpass takes.
    struct rlimit rlim = {0, 0};
    setrlimit(RLIMIT_CORE, &rlim);

    QApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("sudo-askpass"));
    app.setOrganizationName(QStringLiteral("nixos"));

    const QString prompt = argc > 1 ? QString::fromLocal8Bit(argv[1]) : QStringLiteral("Password:");

    QSettings settings;
    int remembered = settings.value(QStringLiteral("duration"), 1).toInt();
    if (remembered < 0 || remembered >= int(sizeof(kChoices) / sizeof(kChoices[0]))) {
        remembered = 1;
    }

    QDialog dlg;
    dlg.setWindowTitle(QStringLiteral("Authentication Required"));
    auto *outer = new QVBoxLayout(&dlg);

    auto *head = new QHBoxLayout;
    auto *icon = new QLabel;
    icon->setPixmap(dlg.style()->standardIcon(QStyle::SP_MessageBoxQuestion).pixmap(48, 48));
    head->addWidget(icon);
    auto *text = new QLabel(prompt.trimmed());
    text->setWordWrap(true);
    head->addWidget(text, 1);
    outer->addLayout(head);

    auto *pwRow = new QHBoxLayout;
    pwRow->addWidget(new QLabel(QStringLiteral("Password:")));
    auto *edit = new QLineEdit;
    edit->setEchoMode(QLineEdit::Password);
    pwRow->addWidget(edit, 1);
    outer->addLayout(pwRow);

    auto *durRow = new QHBoxLayout;
    durRow->addWidget(new QLabel(QStringLiteral("Stay unlocked:")));
    QList<QRadioButton *> radios;
    for (const Choice &c : kChoices) {
        auto *r = new QRadioButton(QString::fromUtf8(c.label));
        radios << r;
        durRow->addWidget(r);
    }
    radios[remembered]->setChecked(true);
    durRow->addStretch(1);
    outer->addLayout(durRow);

    auto *buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel);
    outer->addWidget(buttons);
    QObject::connect(buttons, &QDialogButtonBox::accepted, &dlg, &QDialog::accept);
    QObject::connect(buttons, &QDialogButtonBox::rejected, &dlg, &QDialog::reject);
    QObject::connect(edit, &QLineEdit::returnPressed, &dlg, &QDialog::accept);

    edit->setFocus();
    if (dlg.exec() != QDialog::Accepted) {
        return 1;
    }

    int chosen = remembered;
    for (int i = 0; i < radios.size(); ++i) {
        if (radios[i]->isChecked()) {
            chosen = i;
        }
    }
    settings.setValue(QStringLiteral("duration"), chosen);
    settings.sync();

    QTextStream(stdout) << edit->text() << '\n';
    fflush(stdout);
    schedule(kChoices[chosen].seconds);
    return 0;
}
