/* Copyright 2009 Yorba Foundation
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution. 
 */

//
// DataSet
//
// A DataSet is a collection class used for internal implementations of DataCollection
// and its children.  It may be of use to other classes, however.
//
// The general purpose of DataSet is to provide low-cost implementations of various collection
// operations at a cost of internally maintaining its objects in more than one simple collection.
// contains(), for example, can return a result with hash-table performance while notions of
// ordering are maintained by a SortedList.  The cost is in adding and removing objects (in general,
// there are others).
//
// Because this class has no signalling mechanisms and does not manipulate DataObjects in ways
// they expect to be manipulated (these features are performed by DataCollection), it's probably
// best not to use this class.  Even in cases of building a list of DataObjects for some quick
// operation is probably best done by a Gee.ArrayList.
//

public class DataSet {
    private SortedList<DataObject> list = new SortedList<DataObject>();
    private Gee.HashSet<DataObject> hash_set = new Gee.HashSet<DataObject>();
    private Comparator user_comparator = null;
    
    public DataSet() {
        reset_comparator();
    }
    
    private int64 order_added_comparator(void *a, void *b) {
        return ((DataObject *) a)->internal_get_ordinal() - ((DataObject *) b)->internal_get_ordinal();
    }
    
    private int64 comparator_wrapper(void *a, void *b) {
        if (a == b)
            return 0;
        
        // use the order-added comparator if the user's compare returns equal, to stabilize the
        // sort
        int64 result = user_comparator(a, b);
        if (result == 0)
            result = order_added_comparator(a, b);
        
        assert(result != 0);
        
        return result;
    }
    
    public bool contains(DataObject object) {
        return hash_set.contains(object);
    }
    
    public int get_count() {
        return list.size;
    }
    
    public void reset_comparator() {
        user_comparator = null;
        list.resort(order_added_comparator);
    }
    
    public void set_comparator(Comparator user_comparator) {
        this.user_comparator = user_comparator;
        list.resort(comparator_wrapper);
    }
    
    public Gee.Iterable<DataObject> get_all() {
        // TODO: Returning a copy because of code elsewhere that removes items during an iteration.
        // This needs to be fixed.
        return list.copy();
    }
    
    public DataSet copy() {
        DataSet clone = new DataSet();
        clone.list = list.copy();
        clone.hash_set.add_all(hash_set);
        
        return clone;
    }
    
    public DataObject? get_at(int index) {
        return list.get_at(index);
    }
    
    public int index_of(DataObject object) {
        return list.locate(object);
    }
    
    public bool add(DataObject object) {
        if (!list.add(object))
            return false;
        
        if (!hash_set.add(object)) {
            // attempt to back out of previous operation
            list.remove(object);
            
            return false;
        }
        
        return true;
    }
    
    public bool add_many(Gee.List<DataObject> objects) {
        int count = objects.size;
        if (count == 0)
            return true;
        
        if (!list.add_many(objects))
            return false;
        
        if (!hash_set.add_all(objects)) {
            // back out previous operation
            list.remove_many(objects);
            
            return false;
        }
        
        return true;
    }
    
    public bool remove(DataObject object) {
        bool success = true;
        
        if (!list.remove(object))
            success = false;
        
        if (!hash_set.remove(object))
            success = false;
        
        return success;
    }
    
    public bool remove_many(Gee.List<DataObject> objects) {
        bool success = true;
        
        if (!list.remove_many(objects))
            success = false;
        
        if (!hash_set.remove_all(objects))
            success = false;
        
        return success;
    }
    
    // Returns true if the item has moved.
    public bool resort_object(DataObject object) {
        return list.resort_item(object);
    }
}

//
// DataCollection
//

// A Marker is an object for marking (selecting) DataObjects in a DataCollection to then perform
// an action on all of them.  This mechanism allows for performing mass operations in a generic
// way, as well as dealing with the (perpetual) issue of removing items from a Collection within
// an iterator.
public interface Marker : Object {
    public abstract void mark(DataObject object);
    
    public abstract void mark_many(Gee.Iterable<DataObject> list);
    
    public abstract void mark_all();
    
    public abstract int get_count();
}

// MarkedAction is a callback to perform an action on the marked DataObject.  Return false to
// end iterating.
public delegate bool MarkedAction(DataObject object, Object user);

// A ProgressMonitor allows for notifications of progress on operations on multiple items (via
// the marked interfaces).  Return false if the operation is cancelled and should end immediately.
public delegate bool ProgressMonitor(uint64 current, uint64 total);

// UnknownTotalMonitor is useful when an interface cannot report the total count to a ProgressMonitor,
// only a count, but the total is known by the caller.
public class UnknownTotalMonitor {
    private uint64 total;
    private ProgressMonitor wrapped_monitor;
    
    public UnknownTotalMonitor(uint64 total, ProgressMonitor wrapped_monitor) {
        this.total = total;
        this.wrapped_monitor = wrapped_monitor;
    }
    
    public bool monitor(uint64 count, uint64 total) {
        return wrapped_monitor(count, this.total);
    }
}

// AggregateProgressMonitor is useful when several discrete operations are being performed against
// a single ProgressMonitor.
public class AggregateProgressMonitor {
    private uint64 grand_total;
    private ProgressMonitor wrapped_monitor;
    private uint64 aggregate_count = 0;
    private uint64 last_count = uint64.MAX;
    
    public AggregateProgressMonitor(uint64 grand_total, ProgressMonitor wrapped_monitor) {
        this.grand_total = grand_total;
        this.wrapped_monitor = wrapped_monitor;
    }
    
    public void next_step(string name) {
        debug("next step: %s (%lld/%lld)", name, aggregate_count, grand_total);
        last_count = uint64.MAX;
    }
    
    public bool monitor(uint64 count, uint64 total) {
        // add the difference from the last, unless a new step has started
        aggregate_count += (last_count != uint64.MAX) ? (count - last_count) : count;
        if (aggregate_count > grand_total)
            aggregate_count = grand_total;
        
        // save for next time
        last_count = count;
        
        return wrapped_monitor(aggregate_count, grand_total);
    }
}

// Useful when debugging.
public bool null_progress_monitor(uint64 count, uint64 total) {
    return true;
}

public class DataCollection {
    public const int64 INVALID_OBJECT_ORDINAL = -1;
    
    private class MarkerImpl : Object, Marker {
        public DataCollection owner;
        public Gee.HashSet<DataObject> marked = new Gee.HashSet<DataObject>();
        
        public MarkerImpl(DataCollection owner) {
            this.owner = owner;
            
            // if items are removed from main collection, they're removed from the marked list
            // as well
            owner.items_removed += on_items_removed;
        }
        
        ~MarkerImpl() {
            owner.items_removed -= on_items_removed;
        }
        
        public void mark(DataObject object) {
            assert(owner.internal_contains(object));
            
            marked.add(object);
        }
        
        public void mark_many(Gee.Iterable<DataObject> list) {
            foreach (DataObject object in list) {
                assert(owner.internal_contains(object));
                
                marked.add(object);
            }
        }
        
        public void mark_all() {
            foreach (DataObject object in owner.get_all())
                marked.add(object);
        }
        
        public int get_count() {
            return marked.size;
        }
        
        private void on_items_removed(Gee.Iterable<DataObject> removed) {
            foreach (DataObject object in removed)
                marked.remove(object);
        }
        
        // This method is called by DataCollection when it starts iterating over the marked list ...
        // the marker at this point stops monitoring the collection, preventing a possible
        // removal during an iteration, which is bad.
        public void freeze() {
            owner.items_removed -= on_items_removed;
        }
        
        public void finished() {
            marked = null;
        }
        
        public bool is_valid(DataCollection collection) {
            return (collection == owner) && (marked != null);
        }
    }
    
    private string name;
    private DataSet dataset = new DataSet();
    private Gee.HashMap<string, Value?> properties = new Gee.HashMap<string, Value?>();
    private int64 object_ordinal_generator = 0;
    private int notifies_frozen = 0;
    private bool fire_items_altered = false;
    private bool fire_items_metadata_altered = false;
    private bool fire_ordering_changed = false;

    // When this signal has been fired, the added items are part of the collection
    public virtual signal void items_added(Gee.Iterable<DataObject> added) {
    }
    
    // When this signal is fired, the removed items are no longer part of the collection
    public virtual signal void items_removed(Gee.Iterable<DataObject> removed) {
    }
    
    // When this signal is fired, the removed items are no longer part of the collection
    public virtual signal void contents_altered(Gee.Iterable<DataObject>? added,
        Gee.Iterable<DataObject>? removed) {
    }
    
    // This signal fires whenever any item in the collection signals it has been altered ...
    // this allows monitoring of all objects in the collection without having to register a
    // signal handler for each one
    public virtual signal void item_altered(DataObject item) {
    }
    
    // This signal fires whenever any (or multiple) items in the collection signal they've been
    // altered.  This is more useful than item_altered() because it isn't blocked when notifications
    // are frozen and is called when they are thawed.
    public virtual signal void items_altered() {
    }

    // This signal fires whenever any item in the collection signals its metadata has been altered ...
    // this allows monitoring of all objects in the collection without having to register a
    // signal handler for each one
    public virtual signal void item_metadata_altered(DataObject object) {
    }
    
    // This signal fires whenever any (or multiple) items in the collection signal their
    // metadata has been altered.  Like items_altered(), it isn't blocked when notifications are
    // frozen and is called when they're thawed.
    public virtual signal void items_metadata_altered() {
    }
    
    // Fired when a new sort comparator is registered or an item has moved in the ordering due to
    // an alteration.
    public virtual signal void ordering_changed() {
    }
    
    // Fired when a collection property is set.  The old value is passed as well, null if not set
    // previously.
    public virtual signal void property_set(string name, Value? old, Value val) {
    }
    
    // Fired when a collection property is cleared.
    public virtual signal void property_cleared(string name) {
    }
    
    public DataCollection(string name) {
        this.name = name;
    }
    
    ~DataCollection() {
#if TRACE_DTORS
        debug("DTOR: DataCollection %s", name);
#endif
    }
    
    public virtual string to_string() {
        return "%s (%d)".printf(name, get_count());
    }
    
    // use notifies to ensure proper chronology of signal handling
    protected virtual void notify_items_added(Gee.Iterable<DataObject> added) {
        items_added(added);
    }

    protected virtual void notify_items_removed(Gee.Iterable<DataObject> removed) {
        items_removed(removed);
    }
    
    protected virtual void notify_contents_altered(Gee.Iterable<DataObject>? added,
        Gee.Iterable<DataObject>? removed) {
        contents_altered(added, removed);
    }
    
    protected virtual void notify_item_altered(DataObject item) {
        item_altered(item);
    }
    
    protected virtual void notify_items_altered() {
        items_altered();
    }
    
    protected virtual void notify_item_metadata_altered(DataObject item) {
        item_metadata_altered(item);
    }
    
    protected virtual void notify_items_metadata_altered() {
        items_metadata_altered();
    }
    
    protected virtual void notify_ordering_changed() {
        ordering_changed();
    }
    
    protected virtual void notify_property_set(string name, Value? old, Value val) {
        property_set(name, old, val);
    }
    
    protected virtual void notify_property_cleared(string name) {
        property_cleared(name);
    }
    
    // A singleton list is used when a single item has been added/remove/selected/unselected
    // and needs to be reported via a signal, which uses a list as a parameter ... although this
    // seems wasteful, can't reuse a single singleton list because it's possible for a method
    // that needs it to be called from within a signal handler for another method, corrupting the
    // shared list's contents mid-signal
    protected static Gee.ArrayList<DataObject> get_singleton(DataObject object) {
        Gee.ArrayList<DataObject> singleton = new Gee.ArrayList<DataObject>();
        singleton.add(object);
        
        return singleton;
    }
    
    public virtual bool valid_type(DataObject object) {
        return true;
    }
    
    public virtual void set_comparator(Comparator comparator) {
        dataset.set_comparator(comparator);
        notify_ordering_changed();
    }
    
    // Return to natural ordering of DataObjects, which is order-added
    public virtual void reset_comparator() {
        dataset.reset_comparator();
        notify_ordering_changed();
    }
    
    public virtual Gee.Iterable<DataObject> get_all() {
        return dataset.get_all();
    }
    
    protected DataSet get_dataset_copy() {
        return dataset.copy();
    }
    
    public virtual int get_count() {
        return dataset.get_count();
    }
    
    public virtual DataObject? get_at(int index) {
        return dataset.get_at(index);
    }
    
    public virtual int index_of(DataObject object) {
        return dataset.index_of(object);
    }
    
    public virtual bool contains(DataObject object) {
        return internal_contains(object);
    }
    
    // Because subclasses may filter out objects (by overriding key methods here), need an
    // internal_contains for consistency checking.
    private bool internal_contains(DataObject object) {
        if (!dataset.contains(object))
            return false;
        
        assert(object.get_membership() == this);
        
        return true;
    }
    
    private void internal_add(DataObject object) {
        assert(valid_type(object));
        
        object.internal_set_membership(this, object_ordinal_generator++);
        
        bool added = dataset.add(object);
        assert(added);
    }
    
    private void internal_add_many(Gee.List<DataObject> objects, ProgressMonitor? monitor) {
        int count = objects.size;
        for (int ctr = 0; ctr < count; ctr++) {
            DataObject object = objects.get(ctr);
            assert(valid_type(object));
            
            object.internal_set_membership(this, object_ordinal_generator++);
            
            if (monitor != null)
                monitor(ctr, count);
        }
        
        bool added = dataset.add_many(objects);
        assert(added);
    }
    
    private void internal_remove(DataObject object) {
        object.internal_clear_membership();
        
        bool removed = dataset.remove(object);
        assert(removed);
    }
    
    // Returns false if item is already part of the collection.
    public bool add(DataObject object) {
        if (internal_contains(object)) {
            debug("%s cannot add %s: already present", to_string(), object.to_string());
            
            return false;
        }
        
        internal_add(object);
        
        // fire signal after added using singleton list
        Gee.List<DataObject> added = get_singleton(object);
        notify_items_added(added);
        notify_contents_altered(added, null);
        
        return true;
    }
    
    // Returns number of items added to collection.
    public int add_many(Gee.Iterable<DataObject> objects, ProgressMonitor? monitor = null) {
        Gee.ArrayList<DataObject> added = new Gee.ArrayList<DataObject>();
        foreach (DataObject object in objects) {
            if (internal_contains(object)) {
                debug("%s cannot add %s: already present", to_string(), object.to_string());
                
                continue;
            }
            
            added.add(object);
        }
        
        if (added.size == 0)
            return 0;
        
        internal_add_many(added, monitor);
        
        // signal once all have been added
        if (added.size > 0) {
            notify_items_added(added);
            notify_contents_altered(added, null);
        }
        
        return added.size;
    }
    
    // Obtain a marker to build a list of objects to perform an action upon.
    public Marker start_marking() {
        return new MarkerImpl(this);
    }
    
    // Obtain a marker with a single item marked.  More can be added.
    public Marker mark(DataObject object) {
        Marker marker = new MarkerImpl(this);
        marker.mark(object);
        
        return marker;
    }
    
    // Iterate over all the marked objects performing a user-supplied action on each one.  The
    // marker is invalid after calling this method.
    public void act_on_marked(Marker m, MarkedAction action, ProgressMonitor? monitor = null, 
        Object? user = null) {
        MarkerImpl marker = (MarkerImpl) m;
        
        assert(marker.is_valid(this));
        
        // freeze the marker to prepare it for iteration
        marker.freeze();
        
        uint64 count = 0;
        uint64 total = marker.marked.size;
        
        // iterate, breaking if the callback asks to stop
        foreach (DataObject object in marker.marked) {
            // although marker tracks when items are removed, catch it here as well
            if (!internal_contains(object)) {
                warning("act_on_marked: marker holding ref to unknown %s", object.to_string());
                
                continue;
            }
            
            if (!action(object, user))
                break;
            
            if (monitor != null) {
                if (!monitor(++count, total))
                    break;
            }
        }
        
        // invalidate the marker
        marker.finished();
    }

    // Remove marked items from collection.  This two-step process allows for iterating in a foreach
    // loop and removing without creating a separate list.  The marker is invalid after this call.
    public void remove_marked(Marker m) {
        MarkerImpl marker = (MarkerImpl) m;
        
        assert(marker.is_valid(this));
        
        // freeze the marker before signalling, so it doesn't remove all its items
        marker.freeze();
        
        // remove everything in the marked list
        foreach (DataObject object in marker.marked) {
            // although marker should track items already removed, catch it here as well
            if (!internal_contains(object)) {
                warning("remove_marked: marker holding ref to unknown %s", object.to_string());
                
                continue;
            }
            
            internal_remove(object);
        }
        
        // signal after removing
        if (marker.marked.size > 0) {
            notify_items_removed(marker.marked);
            notify_contents_altered(null, marker.marked);
        }
        
        // invalidate the marker
        marker.finished();
    }
    
    public void clear() {
        if (dataset.get_count() == 0)
            return;
        
        // remove everything in the list, but have to maintain a new list for reporting the signal.
        // Don't use an iterator, as list is modified in internal_remove().
        Gee.ArrayList<DataObject> removed = new Gee.ArrayList<DataObject>();
        do {
            DataObject? object = dataset.get_at(0);
            assert(object != null);
            
            removed.add(object);
            internal_remove(object);
        } while (dataset.get_count() > 0);
        
        // report after removal
        notify_items_removed(removed);
        notify_contents_altered(null, removed);
    }
    
    // close() must be called before disposing of the DataCollection, so all signals may be
    // disconnected and all internal references to the collection can be dropped.  In the bare
    // minimum, all items will be removed from the collection (and the appropriate signals and
    // notify calls will be made).  Subclasses may fire other signals while disposing of their
    // references.  However, if they are entirely synchronized on DataCollection's signals, that
    // may be enough for them to clean up.
    public virtual void close() {
        clear();
    }
    
    // This method is only called by DataObject to report when it has been altered, so observers of
    // this collection may be notified as well.
    public void internal_notify_altered(DataObject object) {
        assert(internal_contains(object));
        
        bool resort_occurred = dataset.resort_object(object);
        
        if (are_notifications_frozen()) {
            fire_items_altered = true;
            fire_ordering_changed = fire_ordering_changed || resort_occurred;
            
            return;
        }
        
        if (resort_occurred)
            notify_ordering_changed();
        
        notify_item_altered(object);
        notify_items_altered();
    }
    
    // This method is only called by DataObject to report when its metadata has been altered, so
    // observers of this collection may be notified as well.
    public void internal_notify_metadata_altered(DataObject object) {
        assert(internal_contains(object));
        
        bool resort_occurred = dataset.resort_object(object);
        
        if (are_notifications_frozen()) {
            fire_items_metadata_altered = true;
            fire_ordering_changed = fire_ordering_changed || resort_occurred;
            
            return;
        }
        
        if (resort_occurred)
            notify_ordering_changed();
        
        notify_item_metadata_altered(object);
        notify_items_metadata_altered();
    }
    
    public Value? get_property(string name) {
        return properties.get(name);
    }
    
    public void set_property(string name, Value val) {
        Value? old = properties.get(name);
        properties.set(name, val);
        
        notify_property_set(name, old, val);
        
        // notify all items in the collection of the change
        int count = dataset.get_count();
        for (int ctr = 0; ctr < count; ctr++)
            dataset.get_at(ctr).notify_collection_property_set(name, old, val);
    }
    
    public void clear_property(string name) {
        if (!properties.unset(name))
            return;
        
        // only notify if the propery was unset (that is, was set to begin with)
        notify_property_cleared(name);
            
        // notify all items
        int count = dataset.get_count();
        for (int ctr = 0; ctr < count; ctr++)
            dataset.get_at(ctr).notify_collection_property_cleared(name);
    }
    
    // This is only guaranteed to freeze notifications that come in from contained objects and
    // need to be propagated with collection signals.  Thus, the caller can freeze notifications,
    // make modifications to many or all member objects, then unthaw and have the aggregated signals
    // fired at once.
    //
    // DataObject/DataSource/DataView should also "eat" their signals as well, to prevent observers
    // from being notified while their collection is frozen.
    //
    // For DataCollection, the signals affected are item_altered, item_metadata_altered, and
    // ordering_changed (and their corresponding signals in DataObject).
    //
    // WARNING: In current implementation, this drops incoming signals from the DataObjects, relying
    // on aggregate signals (items_altered rather than item_altered, etc.) to notify observers.
    // This should be used selectively, and with caution.
    public void freeze_notifications() {
        if (notifies_frozen++ == 0)
            frozen();
    }
    
    public void thaw_notifications() {
        if (notifies_frozen == 0)
            return;
        
        if (--notifies_frozen == 0)
            thawed();
    }
    
    public bool are_notifications_frozen() {
        return notifies_frozen > 0;
    }
    
    // This is called when notifications have frozen.  Child collections should halt notifications
    // until thawed() is called.
    protected virtual void frozen() {
    }
    
    // This is called when enough thaw_notifications() calls have been made.  Child collections
    // should issue caught notifications.
    protected virtual void thawed() {
        if (fire_items_altered) {
            fire_items_altered = false;
            notify_items_altered();
        }
        
        if (fire_items_metadata_altered) {
            fire_items_metadata_altered = false;
            notify_items_metadata_altered();
        }
        
        if (fire_ordering_changed) {
            fire_ordering_changed = false;
            notify_ordering_changed();
        }
    }
}

//
// SourceCollection
//

public class SourceCollection : DataCollection {
    private class DestroyCounter : Object {
        public Marker remove_marker;
        public int delete_failed = 0;
        
        public DestroyCounter(Marker remove_marker) {
            this.remove_marker = remove_marker;
        }
    }
    
    // When this signal is fired, the item is still part of the collection but its own destroy()
    // has already been called.
    public virtual signal void item_destroyed(DataSource source) {
    }
    
    public SourceCollection(string name) {
        base (name);
    }
    
    protected virtual void notify_item_destroyed(DataSource source) {
        item_destroyed(source);
    }
    
    protected override bool valid_type(DataObject object) {
        return object is DataSource;
    }
    
    // Destroy all marked items and optionally have them delete their backing.  Returns the
    // number of items which failed to delete their backing (if delete_backing is true) or zero.
    public int destroy_marked(Marker marker, bool delete_backing, ProgressMonitor? monitor = null) {
        DestroyCounter counter = new DestroyCounter(start_marking());
        
        if (delete_backing)
            act_on_marked(marker, destroy_and_delete_source, monitor, counter);
        else
            act_on_marked(marker, destroy_source, monitor, counter);
        
        // remove once all destroyed
        remove_marked(counter.remove_marker);
        
        return counter.delete_failed;
    }
    
    private bool destroy_and_delete_source(DataObject object, Object user) {
        bool success = false;
        try {
            success = ((DataSource) object).internal_delete_backing();
        } catch (Error err) {
            success = false;
        }
        
        if (!success)
            ((DestroyCounter) user).delete_failed++;
        
        return destroy_source(object, user);
    }
    
    private bool destroy_source(DataObject object, Object user) {
        DataSource source = (DataSource) object;
        
        source.internal_mark_for_destroy();
        source.destroy();
        notify_item_destroyed(source);
        
        ((DestroyCounter) user).remove_marker.mark(source);
        
        return true;
    }
}

public delegate int64 GetSourceDatabaseKey(DataSource source);

// A DatabaseSourceCollection is a SourceCollection that understands database keys (IDs) and the
// nature that a row in a database can only be instantiated once in the system, and so it tracks
// their existance in a map so they can be fetched by their key.
public class DatabaseSourceCollection : SourceCollection {
    private GetSourceDatabaseKey source_key_func;
    private Gee.HashMap<int64?, DataSource> map = new Gee.HashMap<int64?, DataSource>(int64_hash, 
        int64_equal, direct_equal);
        
    public DatabaseSourceCollection(string name, GetSourceDatabaseKey source_key_func) {
        base (name);
        
        this.source_key_func = source_key_func;
    }

    public override void notify_items_added(Gee.Iterable<DataObject> added) {
        foreach (DataObject object in added) {
            DataSource source = (DataSource) object;
            int64 key = source_key_func(source);
            
            assert(!map.has_key(key));
            
            map.set(key, source);
        }
        
        base.notify_items_added(added);
    }
    
    public override void notify_items_removed(Gee.Iterable<DataObject> removed) {
        foreach (DataObject object in removed) {
            int64 key = source_key_func((DataSource) object);

            bool is_removed = map.unset(key);
            assert(is_removed);
        }
        
        base.notify_items_removed(removed);
    }
    
    protected DataSource fetch_by_key(int64 key) {
        return map.get(key);
    }
}

//
// ViewCollection
//

// A ViewManager allows an interface for ViewCollection to monitor a SourceCollection and
// (selectively) add DataViews automatically.
public abstract class ViewManager {
    // This predicate function can be used to filter which DataView objects should be included
    // in the collection as new source objects appear in the SourceCollection.  May be called more
    // than once for any DataSource object.
    public virtual bool include_in_view(DataSource source) {
        return true;
    }
    
    // If include_in_view returns true, this method will be called to instantiate a DataView object
    // for the ViewCollection.
    public abstract DataView create_view(DataSource source);
}

// CreateView is a construction delegate used when mirroring a ViewCollection in another
// ViewCollection.
public delegate DataView CreateView(DataSource source);

// A ViewFilter allows for items in a ViewCollection to be shown or hidden depending on the
// supplied predicate method.  For now, only one ViewFilter may be installed, although this may
// change in the future.  The ViewFilter is used whenever an object is added to the collection
// and when its altered/metadata_altered signals fire.
//
// Return true if view should be visible, false if it should be hidden.
public delegate bool ViewFilter(DataView view);

// A ViewCollection holds DataView objects, which are view instances wrapping DataSource objects.
// Thus, multiple views can exist of a single SourceCollection, each view displaying all or some
// of that SourceCollection.  A view collection also has a notion of order
// (first/last/next/previous) that can be overridden by child classes.  It also understands hidden
// objects, which are withheld entirely from the collection until they're made visible.  Currently
// the only way to hide objects is with a ViewFilter.
//
// The default implementation provides a browser which orders the view in the order they're
// stored in DataCollection, which is not specified.
public class ViewCollection : DataCollection {
    private class ToggleLists : Object {
        public Gee.ArrayList<DataView> selected = new Gee.ArrayList<DataView>();
        public Gee.ArrayList<DataView> unselected = new Gee.ArrayList<DataView>();
    }
    
    private SourceCollection sources = null;
    private ViewManager manager = null;
    private ViewCollection mirroring = null;
    private CreateView mirroring_ctor = null;
    private ViewFilter filter = null;
    private DataSet selected = new DataSet();
    private DataSet visible = null;
    private bool fire_views_altered = false;
    private bool fire_geometries_altered = false;
    
    // TODO: source-to-view mapping ... for now, only one view is allowed for each source.
    // This may need to change in the future.
    private Gee.HashMap<DataSource, DataView> source_map = new Gee.HashMap<DataSource, DataView>(
        direct_hash, direct_equal, direct_equal);
    
    // Signal aggregator.
    public virtual signal void items_selected(Gee.Iterable<DataView> selected) {
    }
    
    // Signal aggregator.
    public virtual signal void items_unselected(Gee.Iterable<DataView> unselected) {
    }
    
    // Signal aggregator.
    public virtual signal void items_state_changed(Gee.Iterable<DataView> changed) {
    }
    
    // Signal aggregator.
    public virtual signal void items_shown(Gee.Iterable<DataView> visible) {
    }
    
    // Signal aggregator.
    public virtual signal void items_hidden(Gee.Iterable<DataView> hidden) {
    }
    
    // Signal aggregator.
    public virtual signal void items_visibility_changed(Gee.Iterable<DataView> changed) {
    }
    
    // Signal aggregator.
    public virtual signal void item_view_altered(DataView view) {
    }
    
    // Signal aggregator.
    public virtual signal void item_geometry_altered(DataView view) {
    }
    
    public virtual signal void views_altered() {
    }
    
    public virtual signal void geometries_altered() {
    }
    
    public ViewCollection(string name) {
        base (name);
    }
    
    protected virtual void notify_item_view_altered(DataView view) {
        item_view_altered(view);
    }
    
    protected virtual void notify_views_altered() {
        views_altered();
    }
    
    protected virtual void notify_item_geometry_altered(DataView view) {
        item_geometry_altered(view);
    }
    
    public virtual void notify_geometries_altered() {
        geometries_altered();
    }
    
    public override void close() {
        halt_monitoring();
        halt_mirroring();
        filter = null;
        
        base.close();
    }
    
    public void monitor_source_collection(SourceCollection sources, ViewManager manager,
        Gee.Iterable<DataSource>? initial = null, ProgressMonitor? monitor = null) {
        halt_monitoring();
        halt_mirroring();
        clear();
        
        this.sources = sources;
        this.manager = manager;
        
        if (initial != null) {
            // add from the initial list handed to us, using the ViewManager to add/remove later
            Gee.ArrayList<DataView> created_views = new Gee.ArrayList<DataView>();
            foreach (DataSource source in initial)
                created_views.add(manager.create_view(source));
            
            add_many(created_views, monitor);
        } else {
            // load in all items from the SourceCollection, filtering with the manager
            add_sources((Gee.Iterable<DataSource>) sources.get_all(), monitor);
        }
        
        // subscribe to the SourceCollection to monitor it for additions and removals, reflecting
        // those changes in this collection
        sources.items_added += on_sources_added;
        sources.items_removed += on_sources_removed;
        sources.item_altered += on_source_altered;
        sources.item_metadata_altered += on_source_altered;
    }
    
    public void halt_monitoring() {
        if (sources != null) {
            sources.items_added -= on_sources_added;
            sources.items_removed -= on_sources_removed;
            sources.item_altered -= on_source_altered;
            sources.item_metadata_altered -= on_source_altered;
        }
        
        sources = null;
        manager = null;
    }
    
    public void mirror(ViewCollection to_mirror, CreateView mirroring_ctor) {
        halt_mirroring();
        halt_monitoring();
        clear();
        
        mirroring = to_mirror;
        this.mirroring_ctor = mirroring_ctor;
        
        // load up with current items
        on_mirror_contents_added(mirroring.get_all());
        
        mirroring.items_added += on_mirror_contents_added;
        mirroring.items_removed += on_mirror_contents_removed;
    }
    
    public void halt_mirroring() {
        if (mirroring != null) {
            mirroring.items_added -= on_mirror_contents_added;
            mirroring.items_removed -= on_mirror_contents_removed;
        }
        
        mirroring = null;
    }
    
    public void install_view_filter(ViewFilter filter) {
        if (this.filter == filter)
            return;
        
        // this currently replaces any existing ViewFilter
        this.filter = filter;
        
        // filter existing items
        reapply_view_filter();
    }
    
    // This is used when conditions outside of the collection have changed and the entire collection
    // should be re-filtered.
    public void reapply_view_filter() {
        if (filter == null)
            return;
        
        // Can't use the marking system because ViewCollection completely overrides DataCollection,
        // hence hidden items can't be marked.  Okay to do this manually because we know what we're
        // doing here in regards to adding and removing objects from lists.
        Gee.ArrayList<DataView> to_show = new Gee.ArrayList<DataView>();
        Gee.ArrayList<DataView> to_hide = new Gee.ArrayList<DataView>();
        
        // iterate through base.all(), otherwise merely iterating the visible items
        foreach (DataObject object in base.get_all()) {
            DataView view = (DataView) object;
            
            if (filter(view)) {
                if (!view.is_visible())
                    to_show.add((DataView) object);
            } else {
                if (view.is_visible())
                    to_hide.add((DataView) object);
            }
        }
        
        if (to_show.size > 0)
            show_items(to_show);
        
        if (to_hide.size > 0)
            hide_items(to_hide);
    }
    
    public void reset_view_filter() {
        this.filter = null;
        
        // reset visibility of all hidden items ... can't use marker for reasons explained in
        // reapply_view_filter().
        Gee.ArrayList<DataView> to_show = new Gee.ArrayList<DataView>();
        foreach (DataObject object in base.get_all()) {
            DataView view = (DataView) object;
            if (view.is_visible()) {
                assert(is_visible(view));
                
                continue;
            }
            
            to_show.add(view);
        }
        
        show_items(to_show);
    }
    
    public override bool valid_type(DataObject object) {
        return object is DataView;
    }
    
    private void on_sources_added(Gee.Iterable<DataSource> added) {
        add_sources(added);
    }
    
    private void add_sources(Gee.Iterable<DataSource> added, ProgressMonitor? monitor = null) {
        // add only source items which are to be included by the manager ... do this in batches
        // to take advantage of add_many()
        Gee.ArrayList<DataView> created_views = new Gee.ArrayList<DataView>();
        foreach (DataSource source in added) {
            if (manager.include_in_view(source))
                created_views.add(manager.create_view(source));
        }
        
        if (created_views.size > 0)
            add_many(created_views, monitor);
    }
    
    private void on_sources_removed(Gee.Iterable<DataSource> removed) {
        // mark all view items associated with the source to be removed
        Marker marker = start_marking();
        foreach (DataSource source in removed) {
            DataView view = source_map.get(source);
            
            // ignore if not represented in this view
            if (view != null)
                marker.mark(view);
        }
        
        remove_marked(marker);
    }
    
    private void on_source_altered(DataObject object) {
        DataSource source = (DataSource) object;
        
        // let ViewManager decide whether or not to keep, but only add if not already present
        // and only remove if already present
        bool include = manager.include_in_view(source);
        if (include && !has_view_for_source(source)) {
            add(manager.create_view(source));
        } else if (!include && has_view_for_source(source)) {
            Marker marker = mark(get_view_for_source(source));
            remove_marked(marker);
        } else if (include && has_view_for_source(source)) {
            DataView view = get_view_for_source(source);
            
            if (selected.contains(view))
                selected.resort_object(view);
            
            if (visible != null && is_visible(view)) {
                if (visible.resort_object(view))
                    notify_ordering_changed();
            }
        }
    }
    
    private void on_mirror_contents_added(Gee.Iterable<DataObject> added) {
        Gee.ArrayList<DataView> to_add = new Gee.ArrayList<DataView>();
        foreach (DataObject object in added) {
            DataView view = (DataView) object;
            
            to_add.add(mirroring_ctor(view.get_source()));
        }
        
        if (to_add.size > 0)
            add_many(to_add);
    }
    
    private void on_mirror_contents_removed(Gee.Iterable<DataObject> removed) {
        Marker marker = start_marking();
        foreach (DataObject object in removed) {
            DataView view = (DataView) object;
            
            DataView our_view = get_view_for_source(view.get_source());
            marker.mark(our_view);
        }
        
        remove_marked(marker);
    }
    
    // Keep the source map and state tables synchronized
    public override void notify_items_added(Gee.Iterable<DataObject> added) {
        Gee.ArrayList<DataView> added_visible = new Gee.ArrayList<DataView>();
        Gee.ArrayList<DataView> added_selected = new Gee.ArrayList<DataView>();
        
        foreach (DataObject object in added) {
            DataView view = (DataView) object;
            source_map.set(view.get_source(), view);
            
            if (view.is_selected())
                added_selected.add(view);
            
            if (filter != null)
                view.internal_set_visible(filter(view));
            
            if (view.is_visible())
                added_visible.add(view);
        }
        
        bool is_added = add_many_visible(added_visible);
        assert(is_added);
        is_added = selected.add_many(added_selected);
        assert(is_added);
        
        base.notify_items_added(added);
    }
    
    // Keep the source map and state tables synchronized
    public override void notify_items_removed(Gee.Iterable<DataObject> removed) {
        foreach (DataObject object in removed) {
            DataView view = (DataView) object;

            bool is_removed = source_map.unset(view.get_source());
            assert(is_removed);
            
            if (view.is_selected())
                remove_selected(view);
            
            if (view.is_visible() && visible != null) {
                is_removed = visible.remove(view);
                assert(is_removed);
            }
        }
        
        base.notify_items_removed(removed);
    }
    
    private void filter_altered_item(DataObject object) {
        if (filter == null)
            return;
        
        DataView view = (DataView) object;
        
        // Can't use the marker system because ViewCollection completely overrides DataCollection
        // and hidden items cannot be marked.
        if (filter(view)) {
            if (!view.is_visible()) {
                Gee.ArrayList<DataView> to_show = new Gee.ArrayList<DataView>();
                to_show.add(view);
                show_items(to_show);
            }
        } else {
            if (view.is_visible()) {
                Gee.ArrayList<DataView> to_hide = new Gee.ArrayList<DataView>();
                to_hide.add(view);
                hide_items(to_hide);
            }
        }
    }
    
    public override void item_altered(DataObject object) {
        filter_altered_item(object);

        base.item_altered(object);
    }
    
    public override void item_metadata_altered(DataObject object) {
        filter_altered_item(object);
        
        base.item_metadata_altered(object);
    }
    
    public override void set_comparator(Comparator comparator) {
        selected.set_comparator(comparator);
        if (visible != null)
            visible.set_comparator(comparator);
        
        base.set_comparator(comparator);
    }
    
    public override void reset_comparator() {
        selected.reset_comparator();
        if (visible != null)
            visible.reset_comparator();
        
        base.reset_comparator();
    }
    
    public override Gee.Iterable<DataObject> get_all() {
        return (visible != null) ? visible.get_all() : base.get_all();
    }
    
    public Gee.Iterable<DataObject> get_all_unfiltered() {
        return base.get_all();
    }    

    public override int get_count() {
        return (visible != null) ? visible.get_count() : base.get_count();
    }
    
    public int get_unfiltered_count() {
        return base.get_count();
    }
    
    public override DataObject? get_at(int index) {
        return (visible != null) ? visible.get_at(index) : base.get_at(index);
    }
    
    public override int index_of(DataObject object) {
        return (visible != null) ? visible.index_of(object) : base.index_of(object);
    }
    
    public override bool contains(DataObject object) {
        // use base method first, which can quickly ascertain if the object is *not* a member of
        // this collection
        if (!base.contains(object))
            return false;
        
        // even if a member, must be visible to be "contained"
        return is_visible((DataView) object);
    }
    
    public virtual DataView? get_first() {
        return (get_count() > 0) ? (DataView?) get_at(0) : null;
    }
    
    public virtual DataView? get_last() {
        return (get_count() > 0) ? (DataView?) get_at(get_count() - 1) : null;
    }
    
    public virtual DataView? get_next(DataView view) {
        if (get_count() == 0)
            return null;
        
        int index = index_of(view);
        if (index < 0)
            return null;
        
        index++;
        if (index >= get_count())
            index = 0;
        
        return (DataView?) get_at(index);
    }
    
    public virtual DataView? get_previous(DataView view) {
        if (get_count() == 0)
            return null;
        
        int index = index_of(view);
        if (index < 0)
            return null;
        
        index--;
        if (index < 0)
            index = get_count() - 1;
        
        return (DataView?) get_at(index);
    }

    // Selects all the marked items.  The marker will be invalid after this call.
    public void select_marked(Marker marker) {
        Gee.ArrayList<DataView> selected = new Gee.ArrayList<DataView>();
        act_on_marked(marker, select_item, null, selected);
        
        if (selected.size > 0) {
            items_selected(selected);
            items_state_changed(selected);
        }
    }
    
    private void add_selected(DataView view) {
        bool added = selected.add(view);
        assert(added);
    }
    
    private void remove_selected(DataView view) {
        bool removed = selected.remove(view);
        assert(removed);
    }
    
    // Selects all items.
    public void select_all() {
        Marker marker = start_marking();
        marker.mark_all();
        select_marked(marker);
    }
    
    private bool select_item(DataObject object, Object user) {
        DataView view = (DataView) object;
        if (view.is_selected()) {
            assert(selected.contains(view));
            
            return true;
        }
            
        view.internal_set_selected(true);
        add_selected(view);

        ((Gee.ArrayList<DataView>) user).add(view);
        
        return true;
    }
    
    // Unselects all the marked items.  The marker will be invalid after this call.
    public void unselect_marked(Marker marker) {
        Gee.ArrayList<DataView> unselected = new Gee.ArrayList<DataView>();
        act_on_marked(marker, unselect_item, null, unselected);
        
        if (unselected.size > 0) {
            items_unselected(unselected);
            items_state_changed(unselected);
        }
    }
    
    // Unselects all items.
    public void unselect_all() {
        if (selected.get_count() == 0)
            return;
        
        Marker marker = start_marking();
        marker.mark_all();
        unselect_marked(marker);
    }
    
    // Unselects all items but the one specified.
    public void unselect_all_but(DataView exception) {
        Marker marker = start_marking();
        foreach (DataObject object in get_all()) {
            DataView view = (DataView) object;
            if (view != exception)
                marker.mark(view);
        }
        
        unselect_marked(marker);
    }
    
    private bool unselect_item(DataObject object, Object user) {
        DataView view = (DataView) object;
        if (!view.is_selected()) {
            assert(!selected.contains(view));
            
            return true;
        }
        
        view.internal_set_selected(false);
        remove_selected(view);
        
        ((Gee.ArrayList<DataView>) user).add(view);
        
        return true;
    }
    
    // Toggle the selection state of all marked items.  The marker will be invalid after this
    // call.
    public void toggle_marked(Marker marker) {
        ToggleLists lists = new ToggleLists();
        act_on_marked(marker, toggle_item, null, lists);
        
        if (lists.selected.size > 0) {
            items_selected(lists.selected);
            items_state_changed(lists.selected);
        }
        
        if (lists.unselected.size > 0) {
            items_unselected(lists.unselected);
            items_state_changed(lists.unselected);
        }
    }
    
    private bool toggle_item(DataObject object, Object user) {
        DataView view = (DataView) object;
        ToggleLists lists = (ToggleLists) user;
        
        // toggle the selection state of the view, adding or removing it from the selected list
        // to maintain state and adding it to the ToggleLists for the caller to signal with
        if (view.internal_toggle()) {
            add_selected(view);
            
            lists.selected.add(view);
        } else {
            remove_selected(view);
            
            lists.unselected.add(view);
        }
        
        return true;
    }
    
    public int get_selected_count() {
        return selected.get_count();
    }
    
    public Gee.Iterable<DataView> get_selected() {
        return (Gee.Iterable<DataView>) selected.get_all();
    }
    
    public DataView? get_selected_at(int index) {
        return (DataView?) selected.get_at(index);
    }
    
    private bool is_visible(DataView view) {
        return (visible != null) ? visible.contains(view) : true;
    }
    
    private bool add_many_visible(Gee.List<DataView> many) {
        if (visible == null)
            return true;
        
        if (!visible.add_many(many))
            return false;
        
        // if all are visible, then revert to using base class's set
        if (visible.get_count() == base.get_count())
            visible = null;
        
        return true;
    }
    
    // This method requires that all items in to_hide are not hidden already.
    private void hide_items(Gee.List<DataView> to_hide) {
        Gee.ArrayList<DataView> unselected = new Gee.ArrayList<DataView>();

        int count = to_hide.size;
        for (int ctr = 0; ctr < count; ctr++) {
            DataView view = to_hide.get(ctr);
            assert(view.is_visible());

            if (view.is_selected()) {
                view.internal_set_selected(false);
                remove_selected(view);
                unselected.add(view);
            }
            
            view.internal_set_visible(false);
        }
        
        if (visible == null) {
            // make a copy of the full set before removing items
            visible = get_dataset_copy();
        }
            
        bool removed = visible.remove_many(to_hide);
        assert(removed);
        
        if (unselected.size > 0) {
            items_state_changed(unselected);
            items_unselected(unselected);
        }
        
        if (to_hide.size > 0) {
            items_hidden(to_hide);
            items_visibility_changed(to_hide);
        }
    }
    
    // This method requires that all items in to_show are hidden already.
    private void show_items(Gee.List<DataView> to_show) {
        Gee.ArrayList<DataView> added_selected = new Gee.ArrayList<DataView>();
        
        int count = to_show.size;
        for (int ctr = 0; ctr < count; ctr++) {
            DataView view = to_show.get(ctr);
            assert(!view.is_visible());
            
            view.internal_set_visible(true);
            
            // see note in hide_item for selection handling with hidden/visible items
            if (view.is_selected()) {
                assert(!selected.contains(view));
                added_selected.add(view);
            }
        }
        
        bool added = add_many_visible(to_show);
        assert(added);
        added = selected.add_many(added_selected);
        assert(added);
        
        if (to_show.size > 0) {
            items_shown(to_show);
            items_visibility_changed(to_show);
        }
    }
    
    public bool has_view_for_source(DataSource source) {
        return source_map.has_key(source);
    }
    
    public DataView? get_view_for_source(DataSource source) {
        return source_map.get(source);
    }

    public Gee.Collection<DataSource> get_sources() {
        Gee.Collection<DataSource> sources = new Gee.ArrayList<DataSource>();
        sources.add_all(source_map.keys);
        
        return sources;
    }
    
    public Gee.Collection<DataSource> get_selected_sources() {
        Gee.Collection<DataSource> sources = new Gee.ArrayList<DataSource>();
        
        int count = selected.get_count();
        for (int ctr = 0; ctr < count; ctr++)
            sources.add(((DataView) selected.get_at(ctr)).get_source());
        
        return sources;
    }
    
    // This is only used by DataView.
    public void internal_notify_view_altered(DataView view) {
        if (!are_notifications_frozen()) {
            notify_item_view_altered(view);
            notify_views_altered();
        } else {
            fire_views_altered = true;
        }
    }
    
    // This is only used by DataView.
    public void internal_notify_geometry_altered(DataView view) {
        if (!are_notifications_frozen()) {
            notify_item_geometry_altered(view);
            notify_geometries_altered();
        } else {
            fire_geometries_altered = true;
        }
    }
    
    protected override void thawed() {
        if (fire_views_altered) {
            fire_views_altered = false;
            notify_views_altered();
        }
        
        if (fire_geometries_altered) {
            fire_geometries_altered = false;
            notify_geometries_altered();
        }
        
        base.thawed();
    }
}

