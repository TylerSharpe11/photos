/* Copyright 2011-2013 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

/* This file is the master unit file for the Direct unit.  It should be edited to include
 * whatever code is deemed necessary.
 *
 * The init () and terminate () methods are mandatory.
 *
 * If the unit needs to be configured prior to initialization, add the proper parameters to
 * the preconfigure () method, implement it, and ensure in init () that it's been called.
 */

namespace Direct {

private File? initial_file = null;

public void preconfigure (File initial_file) {
    Direct.initial_file = initial_file;
}

public void app_init () throws Error {
    Util.init ();
    Threads.init ();
    Db.init ();
    Plugins.init ();
    Slideshow.init ();
    Photos.init ();
    Publishing.init ();
    Core.init ();
    Tags.init ();
    assert (initial_file != null);

    DirectPhoto.init (initial_file);
}

public void app_terminate () {
    DirectPhoto.terminate ();
}

}

