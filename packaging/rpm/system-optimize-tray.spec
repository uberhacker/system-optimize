%global uuid system-optimize@bradvrudney.github.io

Name:           system-optimize-tray
Version:        0.2.0
Release:        1%{?dist}
Summary:        Tray app and dashboard for system-optimize
License:        GPL-3.0-only
URL:            https://github.com/bradvrudney/system-optimize
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch

BuildRequires:  make
BuildRequires:  python3
BuildRequires:  desktop-file-utils

Requires:       python3
Requires:       polkit
Requires:       (python3-pyside6 or python3-pyqt6)
Recommends:     system-optimize

%description
A system tray icon and dashboard for system-optimize: live CPU, memory,
temperature and disk readings, a switch per tuning step, benchmark results
against your baseline and each step's performance history. Changes go
through system-optimize itself, behind a polkit prompt, and can be undone.

On GNOME, install gnome-shell-extension-system-optimize for a native panel
menu; GNOME has no tray of its own.

%package -n gnome-shell-extension-system-optimize
Summary:        GNOME Shell panel menu for system-optimize
Requires:       %{name} = %{version}-%{release}
Requires:       gnome-shell >= 45

%description -n gnome-shell-extension-system-optimize
A native GNOME Shell panel menu for system-optimize: live readings, a switch
per tuning step grouped by category, quick actions and a link to the
dashboard. Enable it with:
  gnome-extensions enable %{uuid}

%package -n system-optimize-agent
Summary:        Optional local-LLM tuning advisor for system-optimize
Requires:       %{name} = %{version}-%{release}
Recommends:     ollama

%description -n system-optimize-agent
Runs a small local model (default qwen3:4b through Ollama, or any llama.cpp
server) on a schedule to look at system-optimize's status and benchmark
history and suggest one change at a time. It never applies anything by
itself: you approve each suggestion. Set it up per user with
/usr/share/system-optimize-tray/install-agent.sh. The 4B model needs about
3-3.5 GB of RAM while it runs.

%prep
%autosetup

%build
# Nothing to build: Python and JavaScript.

%install
%make_install -C tray PREFIX=%{_prefix} SYSCONFDIR=%{_sysconfdir}

%check
desktop-file-validate %{buildroot}%{_datadir}/applications/io.github.bradvrudney.SystemOptimizeTray.desktop
cd tray && QT_QPA_PLATFORM=offscreen python3 -m unittest discover -s tests

%files
%license LICENSE
%doc tray/README.md
%{_bindir}/system-optimize-tray
%{_bindir}/system-optimize-tray-backend
%dir %{_datadir}/system-optimize-tray
%{_datadir}/system-optimize-tray/so_tray/
%{_datadir}/system-optimize-tray/credits.json
%{_datadir}/system-optimize-tray/whats-new.md
%dir %{_libexecdir}/system-optimize
%{_libexecdir}/system-optimize/system-optimize-helper
%{_datadir}/polkit-1/actions/io.github.bradvrudney.system-optimize.policy
%{_datadir}/applications/io.github.bradvrudney.SystemOptimizeTray.desktop
%config(noreplace) %{_sysconfdir}/xdg/autostart/system-optimize-tray-autostart.desktop
%{_datadir}/icons/hicolor/scalable/apps/system-optimize-tray.svg
%{_datadir}/icons/hicolor/symbolic/apps/system-optimize-tray-symbolic.svg

%files -n gnome-shell-extension-system-optimize
%license LICENSE
%{_datadir}/gnome-shell/extensions/%{uuid}/

%files -n system-optimize-agent
%license LICENSE
%{_bindir}/system-optimize-agent
%{_datadir}/system-optimize-tray/so_agent/
%{_datadir}/system-optimize-tray/install-agent.sh

%changelog
* Thu Nov 12 2026 Brad Vrudney <bradvrudney@users.noreply.github.com> - 0.2.0-1
- A quick view and a full view; triage of pressure and journal warnings with
  suggestions that lead to the step; What's new. See whats-new.md.

* Sun Nov 01 2026 Brad Vrudney <bradvrudney@users.noreply.github.com> - 0.1.0-1
- First package: tray app, GNOME Shell extension and optional tuning agent.
