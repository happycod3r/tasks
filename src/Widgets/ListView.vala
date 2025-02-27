/*
* Copyright 2019 elementary, Inc. (https://elementary.io)
*
* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU General Public
* License as published by the Free Software Foundation; either
* version 3 of the License, or (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
* General Public License for more details.
*
* You should have received a copy of the GNU General Public
* License along with this program; if not, write to the
* Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
* Boston, MA 02110-1301 USA
*
*/

public class Tasks.Widgets.ListView : Gtk.Grid {
    public E.Source? source { get; construct; }

    private Gee.Collection<ECal.ClientView> views;

    /*
     * We need to pass a valid S-expression as query to guarantee the callback events are fired.
     *
     * See `e-cal-backend-sexp.c` of evolution-data-server for available S-expressions:
     * https://gitlab.gnome.org/GNOME/evolution-data-server/-/blob/master/src/calendar/libedata-cal/e-cal-backend-sexp.c
     */

    public void add_view (E.Source task_list, string query) {
        try {
            var view = Tasks.Application.model.create_task_list_view (
                task_list,
                query,
                on_tasks_added,
                on_tasks_modified,
                on_tasks_removed );

            lock (views) {
                views.add (view);
            }

        } catch (Error e) {
            critical (e.message);
        }

        if (source != null) {
            E.SourceRegistry? registry = null;
            try {
                registry = Application.model.get_registry_sync ();
                is_gtasks = Application.model.get_collection_backend_name (source, registry) == "google";
            } catch (Error e) {
                warning ("unable to get the registry, assuming task list is not from gtasks");
            }
        }
    }

    public void remove_views () {
        foreach (unowned Gtk.Widget child in task_list.get_children ()) {
            child.destroy ();
        }

        lock (views) {
            foreach (ECal.ClientView view in views) {
                Tasks.Application.model.destroy_task_list_view (view);
            }
            views.clear ();
        }
    }

    private Gtk.Revealer settings_button_revealer;
    private Gtk.Stack title_stack;
    private Gtk.Label scheduled_title;
    private EditableLabel editable_title;

    private Gtk.ListBox add_task_list;
    private Gtk.ListBox task_list;
    private bool is_gtasks;

    public ListView (E.Source? source) {
        Object (source: source);
    }

    construct {
        views = new Gee.ArrayList<ECal.ClientView> ((Gee.EqualDataFunc<ECal.ClientView>?) direct_equal);

        scheduled_title = new Gtk.Label (_("Scheduled")) {
            ellipsize = Pango.EllipsizeMode.END,
            margin_start = 24,
            xalign = 0
        };

        unowned Gtk.StyleContext scheduled_title_context = scheduled_title.get_style_context ();
        scheduled_title_context.add_class (Granite.STYLE_CLASS_H1_LABEL);
        scheduled_title_context.add_class (Granite.STYLE_CLASS_ACCENT);

        editable_title = new EditableLabel () {
            margin_start = 24
        };

        unowned Gtk.StyleContext title_context = editable_title.get_style_context ();
        title_context.add_class (Granite.STYLE_CLASS_H1_LABEL);
        title_context.add_class (Granite.STYLE_CLASS_ACCENT);

        title_stack = new Gtk.Stack () {
            homogeneous = false
        };
        title_stack.add (scheduled_title);
        title_stack.add (editable_title);

        var list_settings_popover = new Tasks.Widgets.ListSettingsPopover ();

        var settings_button = new Gtk.MenuButton () {
            margin_end = 24,
            valign = Gtk.Align.CENTER,
            tooltip_text = _("Edit Name and Appearance"),
            popover = list_settings_popover,
            image = new Gtk.Image.from_icon_name ("view-more-symbolic", Gtk.IconSize.MENU)
        };
        settings_button.get_style_context ().add_class (Gtk.STYLE_CLASS_FLAT);
        settings_button.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);

        settings_button_revealer = new Gtk.Revealer () {
            transition_type = Gtk.RevealerTransitionType.CROSSFADE
        };
        settings_button_revealer.add (settings_button);

        var placeholder = new Gtk.Label (_("No Tasks"));
        placeholder.show ();

        unowned Gtk.StyleContext placeholder_context = placeholder.get_style_context ();
        placeholder_context.add_class (Gtk.STYLE_CLASS_DIM_LABEL);
        placeholder_context.add_class (Granite.STYLE_CLASS_H2_LABEL);

        add_task_list = new Gtk.ListBox () {
            margin_top = 24,
            selection_mode = Gtk.SelectionMode.SINGLE,
            activate_on_single_click = true
        };
        add_task_list.get_style_context ().add_class (Gtk.STYLE_CLASS_BACKGROUND);

        if (source != null) {
            var add_task_row = new Tasks.Widgets.TaskRow.for_source (source);
            add_task_row.task_changed.connect ((task) => {
                Tasks.Application.model.add_task.begin (source, task, (obj, res) => {
                    GLib.Idle.add (() => {
                        try {
                            Tasks.Application.model.add_task.end (res);
                        } catch (Error e) {
                            var error_dialog = new Granite.MessageDialog (
                                _("Adding task failed"),
                                _("The task list registry may be unavailable or unable to be written to."),
                                new ThemedIcon ("dialog-error"),
                                Gtk.ButtonsType.CLOSE
                            );
                            error_dialog.show_error_details (e.message);
                            error_dialog.run ();
                            error_dialog.destroy ();
                        }

                        return GLib.Source.REMOVE;
                    });
                });
            });
            add_task_list.add (add_task_row);
        }

        task_list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.MULTIPLE,
            activate_on_single_click = true
        };
        task_list.set_filter_func (filter_function);
        task_list.set_placeholder (placeholder);
        task_list.set_sort_func (sort_function);
        task_list.set_header_func (header_function);
        task_list.get_style_context ().add_class (Gtk.STYLE_CLASS_BACKGROUND);

        var scrolled_window = new Gtk.ScrolledWindow (null, null) {
            expand = true
        };
        scrolled_window.add (task_list);

        column_spacing = 12;
        attach (title_stack, 0, 0);
        attach (settings_button_revealer, 1, 0);
        attach (add_task_list, 0, 1, 2);
        attach (scrolled_window, 0, 2, 2);

        Application.settings.changed["show-completed"].connect (() => {
            task_list.invalidate_filter ();
        });

        settings_button.toggled.connect (() => {
            if (settings_button.active) {
                list_settings_popover.source = source;
            }
        });

        add_task_list.row_activated.connect ((row) => {
            var task_row = (Tasks.Widgets.TaskRow) row;
            task_row.reveal_child_request (true);
        });

        task_list.row_activated.connect ((row) => {
            var task_row = (Tasks.Widgets.TaskRow) row;
            task_row.reveal_child_request (true);
        });

        editable_title.changed.connect (() => {
            Application.model.update_task_list_display_name.begin (source, editable_title.text, (obj, res) => {
                GLib.Idle.add (() => {
                    try {
                        Application.model.update_task_list_display_name.end (res);
                    } catch (Error e) {
                        editable_title.text = source.display_name;

                        var error_dialog = new Granite.MessageDialog (
                            _("Renaming task list failed"),
                            _("The task list registry may be unavailable or unable to be written to."),
                            new ThemedIcon ("dialog-error"),
                            Gtk.ButtonsType.CLOSE
                        );
                        error_dialog.show_error_details (e.message);
                        error_dialog.run ();
                        error_dialog.destroy ();
                    }

                    return GLib.Source.REMOVE;
                });
            });
        });

        show_all ();
    }

    public void update_request () {
        if (source == null) {
            title_stack.visible_child = scheduled_title;
            settings_button_revealer.reveal_child = false;

        } else {
            title_stack.visible_child = editable_title;
            settings_button_revealer.reveal_child = true;
            editable_title.text = source.dup_display_name ();

            Tasks.Application.set_task_color (source, editable_title);

            task_list.@foreach ((row) => {
                if (row is Tasks.Widgets.TaskRow) {
                    var task_row = (row as Tasks.Widgets.TaskRow);
                    task_row.update_request ();
                }
            });
        }
    }

    [CCode (instance_pos = -1)]
    private bool filter_function (Gtk.ListBoxRow row) {
        if (
            Application.settings.get_boolean ("show-completed") == false &&
            ((TaskRow) row).completed
        ) {
            return false;
        }

        return true;
    }

    [CCode (instance_pos = -1)]
    private int sort_function (Gtk.ListBoxRow row1, Gtk.ListBoxRow row2) {
        var row_a = (Tasks.Widgets.TaskRow) row1;
        var row_b = (Tasks.Widgets.TaskRow) row2;

        if (row_a.completed == row_b.completed) {
            if (is_gtasks) {
                var gtask_position_a = Util.get_gtasks_position_property_value (row_a.task);
                var gtask_position_b = Util.get_gtasks_position_property_value (row_b.task);

                if (gtask_position_a == gtask_position_b) {
                    return row_b.task.get_last_modified ().compare (row_a.task.get_last_modified ());
                }

                return gtask_position_a.collate (gtask_position_b);
            } else {
                var apple_sortorder_a = Util.get_apple_sortorder_property_value (row_a.task);
                if (apple_sortorder_a == null) {
                    apple_sortorder_a = Util.get_apple_sortorder_default_value (row_a.task).as_int ().to_string ();
                }

                var apple_sortorder_b = Util.get_apple_sortorder_property_value (row_b.task);
                if (apple_sortorder_b == null) {
                    apple_sortorder_b = Util.get_apple_sortorder_default_value (row_b.task).as_int ().to_string ();
                }

                return apple_sortorder_a.collate (apple_sortorder_b);
            }
        } else if (row_a.completed && !row_b.completed) {
            return 1;

        } else if (row_b.completed && !row_a.completed) {
            return -1;
        }

        return 0;
    }

    private void header_function (Gtk.ListBoxRow lbrow, Gtk.ListBoxRow? lbbefore) {
        if (source != null || !(lbrow is Tasks.Widgets.TaskRow)) {
            return;
        }
        var row = (Tasks.Widgets.TaskRow) lbrow;
        unowned ICal.Component comp = row.task.get_icalcomponent ();

        if (comp.get_due ().is_null_time ()) {
            return;
        }

        if (lbbefore != null) {
            var before = (Tasks.Widgets.TaskRow) lbbefore;
            unowned ICal.Component comp_before = before.task.get_icalcomponent ();

            if (comp_before.get_due ().compare_date_only (comp.get_due ()) == 0) {
                return;
            }
        }

        var due_date_time = Util.ical_to_date_time (comp.get_due ());
        var header_label = new Granite.HeaderLabel (Tasks.Util.get_relative_date (due_date_time));
        header_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
        header_label.margin_start = 6;

        row.set_header (header_label);
    }

    private void on_tasks_added (Gee.Collection<ECal.Component> tasks, E.Source source) {
        tasks.foreach ((task) => {
            var task_row = new Tasks.Widgets.TaskRow.for_component (task, source, this.source == null);

            task_row.task_completed.connect ((task) => {
                Tasks.Application.model.complete_task.begin (source, task, (obj, res) => {
                    GLib.Idle.add (() => {
                        try {
                            Tasks.Application.model.complete_task.end (res);
                        } catch (Error e) {
                            var error_dialog = new Granite.MessageDialog (
                                _("Completing task failed"),
                                _("The task registry may be unavailable or unable to be written to."),
                                new ThemedIcon ("dialog-error"),
                                Gtk.ButtonsType.CLOSE
                            );
                            error_dialog.show_error_details (e.message);
                            error_dialog.run ();
                            error_dialog.destroy ();
                        }

                        return GLib.Source.REMOVE;
                    });
                });
            });

            task_row.task_changed.connect ((task) => {
                Tasks.Application.model.update_task.begin (source, task, ECal.ObjModType.THIS_AND_FUTURE, (obj, res) => {
                    GLib.Idle.add (() => {
                        try {
                            Tasks.Application.model.update_task.end (res);
                        } catch (Error e) {
                            var error_dialog = new Granite.MessageDialog (
                                _("Updating task failed"),
                                _("The task registry may be unavailable or unable to be written to."),
                                new ThemedIcon ("dialog-error"),
                                Gtk.ButtonsType.CLOSE
                            );
                            error_dialog.show_error_details (e.message);
                            error_dialog.run ();
                            error_dialog.destroy ();
                        }

                        return GLib.Source.REMOVE;
                    });
                });
            });

            task_row.task_removed.connect ((task) => {
                Tasks.Application.model.remove_task.begin (source, task, ECal.ObjModType.ALL, (obj, res) => {
                    GLib.Idle.add (() => {
                        try {
                            Tasks.Application.model.remove_task.end (res);
                        } catch (Error e) {
                            var error_dialog = new Granite.MessageDialog (
                                _("Removing task failed"),
                                _("The task registry may be unavailable or unable to be written to."),
                                new ThemedIcon ("dialog-error"),
                                Gtk.ButtonsType.CLOSE
                            );
                            error_dialog.show_error_details (e.message);
                            error_dialog.run ();
                            error_dialog.destroy ();
                        }

                        return GLib.Source.REMOVE;
                    });
                });
            });

            task_row.unselect.connect (() => {
                task_list.unselect_row (task_row);
            });

            task_list.add (task_row);

            return true;
        });

        Idle.add (() => {
            task_list.invalidate_sort ();
            task_list.show_all ();

            return Source.REMOVE;
        });
    }

    private void on_tasks_modified (Gee.Collection<ECal.Component> tasks) {
        Tasks.Widgets.TaskRow task_row = null;
        var row_index = 0;

        do {
            task_row = (Tasks.Widgets.TaskRow) task_list.get_row_at_index (row_index);

            if (task_row != null) {
                foreach (ECal.Component task in tasks) {
                    if (Util.calcomponent_equal_func (task_row.task, task)) {
                        task_row.task = task;
                        break;
                    }
                }
            }
            row_index++;
        } while (task_row != null);

        Idle.add (() => {
            task_list.invalidate_sort ();

            return Source.REMOVE;
        });
    }

    private void on_tasks_removed (SList<ECal.ComponentId?> cids) {
        unowned Tasks.Widgets.TaskRow? task_row = null;
        var row_index = 0;
        do {
            task_row = (Tasks.Widgets.TaskRow) task_list.get_row_at_index (row_index);

            if (task_row != null) {
                foreach (unowned ECal.ComponentId cid in cids) {
                    if (cid == null) {
                        continue;
                    } else if (cid.get_uid () == task_row.task.get_icalcomponent ().get_uid ()) {
                        task_list.remove (task_row);
                        break;
                    }
                }
            }
            row_index++;
        } while (task_row != null);

        Idle.add (() => {
            task_list.invalidate_sort ();

            return Source.REMOVE;
        });
    }
}
