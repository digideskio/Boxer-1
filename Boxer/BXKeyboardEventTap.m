/* 
 Boxer is copyright 2011 Alun Bestor and contributors.
 Boxer is released under the GNU General Public License 2.0. A full copy of this license can be
 found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import <AppKit/AppKit.h> //For NSApp
#import <Carbon/Carbon.h> //For keycodes
#import <IOKit/hidsystem/ev_keymap.h> //For media key codes

#import "BXKeyboardEventTap.h"
#import "BXContinuousThread.h"


@interface BXKeyboardEventTap ()

//The dedicated thread on which our tap runs.
@property (retain) BXContinuousThread *tapThread;

//Our CGEventTap callback. Receives the BXKeyboardEventTap instance as the userInfo parameter,
//and passes handling directly on to it. 
static CGEventRef _handleEventFromTap(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo);

//Actually does the work of handling the event. Checks
- (CGEventRef) _handleEvent: (CGEventRef)event
                     ofType: (CGEventType)type
                  fromProxy: (CGEventTapProxy)proxy;

//Creates an event tap, and starts up a dedicated thread to monitor it (if usesDedicatedThread is YES)
//or adds it to the main thread (if usesDedicatedThread is NO).
- (void) _startTapping;

//Removes the tap and any dedicated thread we were running it on.
- (void) _stopTapping;

//Runs continuously on tapThread, listening to the tap until _stopTapping is called and the thread is cancelled.
- (void) _runTapInDedicatedThread;

@end


@implementation BXKeyboardEventTap
@synthesize enabled = _enabled;
@synthesize usesDedicatedThread = _usesDedicatedThread;
@synthesize tapThread = _tapThread;
@synthesize delegate = _delegate;

- (id) init
{
    if ((self = [super init]))
    {
        self.usesDedicatedThread = NO;
        
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver: self
                   selector: @selector(applicationDidBecomeActive:)
                       name: NSApplicationDidBecomeActiveNotification
                     object: NSApp];
    }
    return self;
}

- (void) applicationDidBecomeActive: (NSNotification *)notification
{
    //Listen for when Boxer becomes the active application and re-check
    //the availability of the accessibility API at this point.
    //If the API is available, attempt to reestablish a tap if we're
    //enabled and don't already have one (which means it failed when
    //we tried it the last time.)
    [self willChangeValueForKey: @"canTapEvents"];
    if (!self.isTapping && self.isEnabled && self.canTapEvents)
    {
        [self _startTapping];
    }
    [self didChangeValueForKey: @"canTapEvents"];
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver: self];
    
    [self _stopTapping];
    self.tapThread = nil;
    
    [super dealloc];
}

- (void) setEnabled: (BOOL)flag
{
    if (_enabled != flag)
    {
        _enabled = flag;
        
        if (flag) [self _startTapping];
        else [self _stopTapping];
    }
}

- (void) setUsesDedicatedThread: (BOOL)usesDedicatedThread
{
    if (usesDedicatedThread != self.usesDedicatedThread)
    {
        BOOL wasTapping = self.isTapping;
        if (wasTapping)
        {
            [self _stopTapping];
        }
        
        _usesDedicatedThread = usesDedicatedThread;
        
        if (wasTapping)
        {
            [self _startTapping];
        }
    }
}

- (BOOL) canTapEvents
{
    return (AXAPIEnabled() || AXIsProcessTrusted());
}

- (BOOL) isTapping
{
    return _tap != NULL;
}

- (void) _startTapping
{
    if (!self.isTapping)
    {
        //Create the event tap, and keep a reference to it as an instance variable
        //so that we can access it from our callback if needed.
        //This will fail and return NULL if Boxer does not have permission to tap
        //keyboard events.
        CGEventMask eventTypes = CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(NX_SYSDEFINED);
        _tap = CGEventTapCreate(kCGSessionEventTap,
                                kCGHeadInsertEventTap,
                                kCGEventTapOptionDefault,
                                eventTypes,
                                _handleEventFromTap,
                                self);
        
        if (_tap)
        {
            _source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
            
            //Decide whether to run the tap on a dedicated thread or on the main thread.
            if (self.usesDedicatedThread)
            {
                //_runTapInDedicatedThread will handle adding and removing the source
                //on its own run loop.
                self.tapThread = [[[BXContinuousThread alloc] initWithTarget: self
                                                                    selector: @selector(_runTapInDedicatedThread)
                                                                      object: nil] autorelease];
                
                [self.tapThread start];
            }
            else
            {
                CFRunLoopAddSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
            }
        }
    }
}

- (void) _stopTapping
{
    if (self.isTapping)
    {
        if (self.usesDedicatedThread && self.tapThread)
        {
            [self.tapThread cancel];
            [self.tapThread waitUntilFinished];
            self.tapThread = nil;
        }
        else
        {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
        }
        
        //Clean up the event tap and source after ourselves.
        CFMachPortInvalidate(_tap);
        CFRunLoopSourceInvalidate(_source);
        
        CFRelease(_source);
        CFRelease(_tap);
        
        _tap = NULL;
        _source = NULL;
    }
}

- (void) _runTapInDedicatedThread
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    if (_source != NULL)
    {
        CFRetain(_source);
        
        //Create a source on the thread's run loop so that we'll receive messages
        //from the tap when an event comes in.
        CFRunLoopAddSource(CFRunLoopGetCurrent(), _source, kCFRunLoopCommonModes);
        
        //Run this thread's run loop until we're told to stop, processing event-tap
        //callbacks and other messages on this thread.
        [(BXContinuousThread *)[NSThread currentThread] runUntilCancelled];
        
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), _source, kCFRunLoopCommonModes);
        
        CFRelease(_source);
    }
    
    [pool drain];
}

- (CGEventRef) _handleEvent: (CGEventRef)event
                     ofType: (CGEventType)type
                  fromProxy: (CGEventTapProxy)proxy
{
    //If we're not enabled or we have no way of validating the events, give up early
    if (!self.enabled || !self.delegate)
    {
        return event;
    }
    
    BOOL shouldCapture = NO;
    switch (type)
    {
        case kCGEventKeyDown:
        case kCGEventKeyUp:
        case NX_SYSDEFINED:
        {
            //First try and make this into a cocoa event
            NSEvent *cocoaEvent = nil;
            @try
            {
                cocoaEvent = [NSEvent eventWithCGEvent: event];
            }
            @catch (NSException *exception) {
                //If the event could not be converted into a cocoa event, give up
            }
            
            if (cocoaEvent)
            {
                if (type == NX_SYSDEFINED)
                {
                    shouldCapture = [self.delegate eventTap: self shouldCaptureSystemDefinedEvent: cocoaEvent];
                }
                else
                {
                    shouldCapture = [self.delegate eventTap: self shouldCaptureKeyEvent: cocoaEvent];
                }
            }
            
            break;
        }
        
        case kCGEventTapDisabledByTimeout:
        {
            //Re-enable the event tap if it has been disabled after a timeout.
            //(This may occur if our thread has been blocked for some reason.)
            CGEventTapEnable(_tap, YES);
            break;
        }
    }
    
    if (shouldCapture)
    {
        ProcessSerialNumber PSN;
        OSErr error = GetCurrentProcess(&PSN);
        if (error == noErr)
        {
            CGEventPostToPSN(&PSN, event);
            
            //Returning NULL cancels the original event
            return NULL;
        }
    }
    
    return event;
}

static CGEventRef _handleEventFromTap(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo)
{
    CGEventRef returnedEvent = event;
    
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    BXKeyboardEventTap *tap = (BXKeyboardEventTap *)userInfo;
    if (tap)
    {
        returnedEvent = [tap _handleEvent: event ofType: type fromProxy: proxy];
    }
    [pool drain];
    
    return returnedEvent;
}

@end
