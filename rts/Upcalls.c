/* -----------------------------------------------------------------------------
 *
 * (c) The GHC Team, 2000-2009
 *
 * Upcall support
 *
 * ---------------------------------------------------------------------------*/

#include "PosixSource.h"
#include "Rts.h"

#include "Schedule.h"
#include "RtsUtils.h"
#include "Trace.h"
#include "Prelude.h"
#include "Threads.h"
#include "Upcalls.h"

// Initialization
UpcallQueue*
allocUpcallQueue (void)
{
  return newWSDeque (4096); //TODO KC -- Add this to RtsFlags.UpcallFlags
}

// Add a new upcall
void
addNewUpcall (Capability* cap, StgClosure* p)
{
  if (!pushWSDeque (cap->upcall_queue, p))
    barf ("addNewUpcall overflow!!");
}

// returns true if the given upcall is a suspended upcall, i.e) it is a
// reference to a StgStack.
rtsBool
isSuspendedUpcall (StgClosure* p)
{
  return (get_itbl(p)->type == STACK);
}


StgTSO*
prepareUpcallThread (Capability* cap, StgTSO* current_thread)
{
  StgTSO *upcall_thread;

  upcall_thread = cap->upcall_thread;

  //If cap->upcall_thread is the upcall thread, then swap it with the current
  //thread (if present).
  if (isUpcallThread(upcall_thread)) {
      cap->upcall_thread = current_thread;
  }

  StgClosure* upcall = popUpcallQueue (cap->upcall_queue);
  if (isSuspendedUpcall (upcall))
    upcall_thread->stackobj = (StgStack*)upcall;
  else
    pushCallToClosure (cap, upcall_thread, upcall);

  return upcall_thread;
}

StgTSO*
retoreCurrentThreadIfNecessary (Capability* cap, StgTSO* current_thread) {

  StgTSO* return_thread = current_thread;

  //Given Thread is the upcall thread
  if (isUpcallThread (current_thread)) {
    return_thread = cap->upcall_thread;
    //Save the upcall thread
    cap->upcall_thread = current_thread;
  }

  return return_thread;
}

/* GC for the upcall queue, called inside Capability.c for all capabilities in
 * turn. */
void
traverseUpcallQueue (evac_fn eval, void* user, Capability *cap)
{
  //XXX KC -- Copy paste from traverseSparkPool. Merge these if possible.
  StgClosure **upcallp;
  UpcallQueue *queue;
  StgWord top,bottom, modMask;

  queue = cap->upcalls;

  ASSERT_WSDEQUE_INVARIANTS(queue);

  top = queue->top;
  bottom = queue->bottom;
  upcallp = (StgClosurePtr*)queue->elements;
  modMask = queue->moduloSize;

  while (top < bottom) {
    /* call evac for all closures in range (wrap-around via modulo)
     * In GHC-6.10, evac takes an additional 1st argument to hold a
     * GC-specific register, see rts/sm/GC.c::mark_root()
     */
    evac( user , upcallp + (top & modMask) );
    top++;
  }

  debugTrace(DEBUG_upcalls,
             "traversed upcall queue, len=%ld; (hd=%ld; tl=%ld)",
             upcallQueueSize(queue), queue->bottom, queue->top);
}
