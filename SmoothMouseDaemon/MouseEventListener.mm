
#import "MouseEventListener.h"
#import "debug.h"
#import "mach_timebase_util.h"
#import "MouseSupervisor.h"
#import "InterruptListener.h"
#import "DriverEventLog.h"
#import "Daemon.h"

//#include <CarbonEvents.h>

extern "C" {
    extern Boolean
    IsMouseCoalescingEnabled(void);

    extern OSStatus
    SetMouseCoalescingEnabled(
                              Boolean    inNewState,
                              Boolean *  outOldState);
}

const char *cg_event_type_to_string(CGEventType type) {
    switch (type) {
        case kCGEventMouseMoved: return "kCGEventMouseMoved";
        case kCGEventLeftMouseDragged: return "kCGEventLeftMouseDragged";
        case kCGEventRightMouseDragged: return "kCGEventRightMouseDragged";
        case kCGEventOtherMouseDragged: return "kCGEventOtherMouseDragged";
        default: return "?";
    }
}

@implementation MouseEventListener

CGEventRef
myCGEventCallback(CGEventTapProxy proxy, CGEventType type,
                  CGEventRef event, void *refcon)
{
    int64_t deltaX = CGEventGetIntegerValueField(event, kCGMouseEventDeltaX);
    int64_t deltaY = CGEventGetIntegerValueField(event, kCGMouseEventDeltaY);

    if ([[Config instance] latencyEnabled]) {
        static mach_timebase_info_data_t machTimebaseInfo;
        uint64_t timestampInterrupt = 0;
        uint64_t timestampNow = 0;
        uint64_t timestampKext = 0;

        if (machTimebaseInfo.denom == 0) {
            mach_timebase_info(&machTimebaseInfo);
        }

        BOOL ok;

        ok = [sInterruptListener get:&timestampInterrupt];

        if (!ok) {
            NSLog(@"No timestamp from interrupt (event injected?)");
            exit(1);
        }

        driver_event_t driverEvent;
        ok = [sDriverEventLog get:&driverEvent];

        if (!ok) {
            timestampKext = 0;
        } else {
            timestampKext = driverEvent.kextTimestamp;
        }

        timestampInterrupt = convert_from_mach_timebase_to_nanos(timestampInterrupt, &machTimebaseInfo);
        timestampKext = convert_from_mach_timebase_to_nanos(timestampKext, &machTimebaseInfo);
        timestampNow = convert_from_mach_timebase_to_nanos(mach_absolute_time(), &machTimebaseInfo);

        float latencyInterrupt = (timestampNow - timestampInterrupt) / 1000000.0;
        float latencyKext      = (timestampNow - timestampKext) / 1000000.0;

        LOG(@"Application received mouse event: %s (%d), dx: %d, dy: %d, lat int: %f ms, lat kext: %f ms, int events: %d",
            cg_event_type_to_string(type),
            type,
            (int)deltaX,
            (int)deltaY,
            (latencyInterrupt),
            (timestampKext == 0 ? 0 : latencyKext),
            [sInterruptListener numEvents]);
    }

    if (type == kCGEventMouseMoved ||
        type == kCGEventLeftMouseDragged ||
        type == kCGEventRightMouseDragged ||
        type == kCGEventOtherMouseDragged) {

        //CGPoint location = CGEventGetLocation(event);

        BOOL match = [sMouseSupervisor popMoveEvent:(int) deltaX: (int) deltaY];
        if (!match) {
            mouse_refresh(REFRESH_REASON_POSITION_TAMPERING);
            if ([[Config instance] debugEnabled]) {
                if ([[Config instance] mouseEnabled] || [[Config instance] trackpadEnabled]) {
                    LOG(@"Mouse location tampering detected");
                }
            }
        } else {
            //NSLog(@"MATCH: %d, queue size: %d, delta x: %f, delta y: %f",
            //      match,
            //      [sMouseSupervisor numItems],
            //      [event deltaX],
            //      [event deltaY]
            //      );
        }
    } else if (type == kCGEventLeftMouseDown) {
        //LOG(@"LEFT MOUSE CLICK (ClickCount: %ld)", (long)[event clickCount]);
        if ([[Config instance] debugEnabled]) {
            [sMouseSupervisor popClickEvent];
            if ([sMouseSupervisor hasClickEvents]) {
                LOG(@"WARNING: click event probably lost");
                if ([[Config instance] sayEnabled]) {
                    [[Daemon instance] say:@"There was one lost mouse click"];
                }
                [sMouseSupervisor resetClickEvents];
            }
        }
    } else if (type == NSLeftMouseDown) {
        //LOG(@"LEFT MOUSE RELEASE");
    }

    return event;
}

-(void) start:(NSRunLoop *)runLoop {
    //LOG(@"MouseEventListener::start");

    SetMouseCoalescingEnabled(true, NULL);

    CGEventMask eventMask;

    // Create an event tap. We are interested in mouse movements.
    eventMask  = 0;
    eventMask |= CGEventMaskBit(kCGEventMouseMoved);
    eventMask |= CGEventMaskBit(kCGEventLeftMouseDragged);
    eventMask |= CGEventMaskBit(kCGEventRightMouseDragged);
    eventMask |= CGEventMaskBit(kCGEventOtherMouseDragged);
    eventMask |= CGEventMaskBit(kCGEventLeftMouseDown);
    eventMask |= CGEventMaskBit(kCGEventLeftMouseUp);
    eventMask |= CGEventMaskBit(kCGEventRightMouseDown);
    eventMask |= CGEventMaskBit(kCGEventRightMouseUp);
    eventMask |= CGEventMaskBit(kCGEventOtherMouseDown);
    eventMask |= CGEventMaskBit(kCGEventOtherMouseUp);

    eventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, 0, eventMask, myCGEventCallback, NULL);
    if (!eventTap) {
        fprintf(stderr, "failed to create event tap\n");
        exit(1);
    }

    runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);

    CFRunLoopAddSource([runLoop getCFRunLoop], runLoopSource, kCFRunLoopCommonModes);

    CGEventTapEnable(eventTap, true);

    running = true;
}

-(void) stop:(NSRunLoop *)runLoop {
    //LOG(@"MouseEventListener::stop");

    if (running) {
        running = false;

        CGEventTapEnable(eventTap, false);

        CFRunLoopRemoveSource([runLoop getCFRunLoop], runLoopSource, kCFRunLoopCommonModes);

        CFRelease(runLoopSource);

        CFRelease(eventTap);
    }
}

-(bool) isRunning {
    return running;
}

@end
