#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // The only window: a second start brings it up instead of a new one.
  GtkWindow* window;
  // Calendar files opened with Famio (`famio/open_file`), kept until Dart
  // takes them.
  FlMethodChannel* open_file;
  gchar* pending_name;
  GBytes* pending_bytes;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// A calendar file, not a film.
static const gsize kMaxFileBytes = 10 * 1024 * 1024;

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// `famio/open_file`: Dart takes the waiting file.
static void open_file_cb(FlMethodChannel* channel, FlMethodCall* call,
                         gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  g_autoptr(FlValue) file = nullptr;
  if (g_strcmp0(fl_method_call_get_name(call), "take") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  if (self->pending_bytes != nullptr) {
    file = fl_value_new_map();
    fl_value_set_string_take(file, "name",
                             fl_value_new_string(self->pending_name));
    gsize length = 0;
    const uint8_t* bytes = static_cast<const uint8_t*>(
        g_bytes_get_data(self->pending_bytes, &length));
    fl_value_set_string_take(file, "bytes",
                             fl_value_new_uint8_list(bytes, length));
    g_clear_pointer(&self->pending_name, g_free);
    g_clear_pointer(&self->pending_bytes, g_bytes_unref);
  }
  fl_method_call_respond_success(call, file, nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window != nullptr) {
    gtk_window_present(self->window);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;
  g_object_add_weak_pointer(G_OBJECT(window),
                            reinterpret_cast<gpointer*>(&self->window));

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
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Famio");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Famio");
  }

  gtk_window_set_default_size(window, 1280, 720);

  // Window/taskbar icon from the bundle's data directory.
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe != nullptr) {
    g_autofree gchar* dir = g_path_get_dirname(exe);
    g_autofree gchar* icon =
        g_build_filename(dir, "data", "app_icon.png", nullptr);
    gtk_window_set_icon_from_file(window, icon, nullptr);
  }

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view),
                                                  "FamioOpenedFiles");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_clear_object(&self->open_file);
  self->open_file =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "famio/open_file", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->open_file, open_file_cb,
                                            self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::open: "Öffnen mit" in the file manager, also when
// a second start handed its file to this Famio.
static void my_application_open(GApplication* application, GFile** files,
                                gint n_files, const gchar* hint) {
  MyApplication* self = MY_APPLICATION(application);
  const gboolean running = self->window != nullptr;
  for (gint i = 0; i < n_files; i++) {
    gchar* contents = nullptr;
    gsize length = 0;
    if (!g_file_load_contents(files[i], nullptr, &contents, &length, nullptr,
                              nullptr)) {
      continue;
    }
    if (length > kMaxFileBytes) {
      g_free(contents);
      continue;
    }
    g_free(self->pending_name);
    self->pending_name = g_file_get_basename(files[i]);
    g_clear_pointer(&self->pending_bytes, g_bytes_unref);
    self->pending_bytes = g_bytes_new_take(contents, length);
    break;
  }
  my_application_activate(application);
  // On a fresh start Dart asks by itself.
  if (running && self->pending_bytes != nullptr && self->open_file != nullptr) {
    fl_method_channel_invoke_method(self->open_file, "opened", nullptr,
                                    nullptr, nullptr, nullptr);
  }
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  // Files go to the Famio that already runs, when there is one.
  g_autoptr(GPtrArray) files = g_ptr_array_new_with_free_func(g_object_unref);
  for (gchar** arg = *arguments + 1; *arg != nullptr; arg++) {
    if (**arg != '-') {
      g_ptr_array_add(files, g_file_new_for_commandline_arg(*arg));
    }
  }
  if (files->len > 0) {
    g_application_open(application,
                       reinterpret_cast<GFile**>(files->pdata),
                       static_cast<gint>(files->len), "");
  } else {
    g_application_activate(application);
  }
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  if (self->window != nullptr) {
    g_object_remove_weak_pointer(G_OBJECT(self->window),
                                 reinterpret_cast<gpointer*>(&self->window));
    self->window = nullptr;
  }
  g_clear_object(&self->open_file);
  g_clear_pointer(&self->pending_name, g_free);
  g_clear_pointer(&self->pending_bytes, g_bytes_unref);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->open = my_application_open;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  // One Famio per session (over D-Bus): a second start, also from "Öffnen
  // mit", goes to the first. Release builds only, so `flutter run` does not
  // hand over to an installed Famio.
#ifdef NDEBUG
  const GApplicationFlags flags = G_APPLICATION_HANDLES_OPEN;
#else
  const GApplicationFlags flags = static_cast<GApplicationFlags>(
      G_APPLICATION_NON_UNIQUE | G_APPLICATION_HANDLES_OPEN);
#endif
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     flags, nullptr));
}
