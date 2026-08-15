#include "my_application.h"

int main(int argc, char** argv) {
  // The name the desktop identifies this process by. GTK 3 uses g_get_prgname()
  // for the Wayland surface's xdg_toplevel app_id and for the X11 WM_CLASS, and
  // both default to the executable's name — "liberated_bread_mobile".
  //
  // That default is what leaves the app anonymous in a Wayland session. A
  // Wayland compositor draws no per-window icon of its own: it matches the
  // app_id against an installed .desktop file and uses the icon named there, so
  // an app_id matching nothing gets the generic placeholder no matter what
  // my_application.cc sets. Naming the process APPLICATION_ID makes it match
  // the entry scripts/install-linux-desktop-entry.sh installs
  // (ca.pigscanfly.liberatedbread.desktop), which is the reverse-DNS convention
  // the desktop expects and the same identifier as the Android applicationId
  // and the Xcode bundle id.
  //
  // Set before my_application_new(): g_application_run() fills prgname in from
  // argv[0] if it is still unset by the time it runs, and the Wayland backend
  // reads it when the first surface is created.
  g_set_prgname(APPLICATION_ID);

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
