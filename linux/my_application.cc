#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// The icon sizes linux/CMakeLists.txt copies into data/resources/. This list
// and tool/branding/generate_icons.mjs's LINUX list are the same contract in
// two places; a name that only exists on one side fails silently at runtime,
// which is why a total miss below is a g_warning rather than a debug line —
// and why test/core/linux_app_icon_test.dart reads both lists and fails when
// they drift.
//
// All of them are handed over rather than one large one: a desktop draws this
// icon at 16px in a window list and much larger in an alt-tab overlay, and the
// call below hands the whole set over so each surface can take the size it
// wants. Given only a large one, the compositor downscales it itself — that is
// where a muddy taskbar icon comes from.
//
// The 256 is in the list for the .desktop/hicolor install path
// (scripts/install-linux-desktop-entry.sh), NOT for this call: GDK's X11
// backend drops any icon over 128px when it writes _NET_WM_ICON, so the 256
// never reaches a window property even when it is the only one supplied.
// Verified by reading the property back off a running window; do not "fix" the
// apparent gap by removing 128, which is the largest size X11 actually keeps.
static const int kAppIconSizes[] = {16, 24, 32, 48, 64, 128, 256};

// Sets the icon every window of this application inherits.
//
// WHY IT IS LOADED FROM DISK AND NOT LOOKED UP BY NAME. The GTK-idiomatic call
// is gtk_window_set_default_icon_name(APPLICATION_ID), which resolves through
// the freedesktop icon theme. That only finds anything once the app is
// INSTALLED — icons under a hicolor directory, a .desktop file beside them.
// This app is normally run straight out of build/linux/x64/<mode>/bundle by
// `flutter run` or scripts/run-linux.sh, where no such install exists, so a
// theme lookup finds nothing and the window falls back to a generic icon.
// Loading the bundled PNGs works in both situations and needs no install step.
//
// Failure is soft on purpose: a missing icon is a cosmetic defect, and refusing
// to start the app over one would be a far worse bug than the one being fixed.
//
// WAYLAND CAVEAT. Under X11 (and XWayland) this sets _NET_WM_ICON and is what
// the window list, the taskbar and alt-tab all read. A native Wayland session
// ignores per-window icons entirely and matches the surface's app_id to an
// installed .desktop file instead — which is why main.cc sets the process name
// to APPLICATION_ID, and why scripts/install-linux-desktop-entry.sh exists to
// install a matching entry. Neither is a substitute for this: X11 sessions
// have no .desktop file to consult, and Wayland has no window icon to read.
static void my_application_set_app_icon() {
  // The bundle layout is <bundle>/<binary> with <bundle>/data alongside it, so
  // the executable's own directory is the anchor. Resolving it from
  // /proc/self/exe rather than from argv[0] means it is right however the app
  // was launched — via PATH, via a symlink, or from a .desktop file whose
  // working directory is somewhere else entirely.
  g_autofree gchar* exe_path = g_file_read_link("/proc/self/exe", nullptr);
  if (exe_path == nullptr) {
    g_warning("Could not resolve /proc/self/exe; window icon not set.");
    return;
  }
  g_autofree gchar* bundle_dir = g_path_get_dirname(exe_path);

  GList* icons = nullptr;
  for (size_t i = 0; i < G_N_ELEMENTS(kAppIconSizes); i++) {
    g_autofree gchar* name =
        g_strdup_printf("app_icon_%d.png", kAppIconSizes[i]);
    g_autofree gchar* path =
        g_build_filename(bundle_dir, "data", "resources", name, nullptr);

    g_autoptr(GError) error = nullptr;
    GdkPixbuf* pixbuf = gdk_pixbuf_new_from_file(path, &error);
    if (pixbuf == nullptr) {
      g_debug("Skipping window icon %s: %s", path, error->message);
      continue;
    }
    icons = g_list_append(icons, pixbuf);
  }

  if (icons == nullptr) {
    g_warning(
        "No app icons found under %s/data/resources — the window will use a "
        "generic icon. Check the resources install() in linux/CMakeLists.txt.",
        bundle_dir);
    return;
  }

  // Takes its own reference to each pixbuf, so the list and our references are
  // ours to drop straight afterwards.
  gtk_window_set_default_icon_list(icons);
  g_list_free_full(icons, g_object_unref);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  // Product name, not the pubspec package name `flutter create` puts here.
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Liberated Bread");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Liberated Bread");
  }

  // Portrait and phone-shaped, NOT the template's 1280x720 landscape default.
  // This target exists so the mobile UI can be iterated on without booting an
  // emulator, and every screen in lib/screens/ is laid out for a phone: at
  // 1280x720 the forms stretch to absurd line lengths and the layout you are
  // looking at is not the one that ships. 430x900 is close to a large phone's
  // logical size (iPhone 15 Pro Max is 430x932) while still fitting on a
  // 1080p display once the header bar and a taskbar are accounted for.
  // The window stays freely resizable, so responsive breakpoints can still be
  // checked by dragging it wider.
  gtk_window_set_default_size(window, 430, 900);
  gtk_widget_show(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
     g_warning("Failed to register: %s", error->message);
     *exit_status = 1;
     return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Before activate(), which is where the window is created: this sets the
  // DEFAULT icon list, so every window inherits it at construction and there
  // is no frame where one is drawn with the generic icon.
  my_application_set_app_icon();

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_NON_UNIQUE,
                                     nullptr));
}
