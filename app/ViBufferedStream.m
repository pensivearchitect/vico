#define FORCE_DEBUG
#include <sys/uio.h>
#include <unistd.h>

#import "ViBufferedStream.h"
#include "logging.h"

@implementation ViStreamBuffer

@synthesize ptr, left, length;

- (ViStreamBuffer *)initWithData:(NSData *)aData
{
	if ((self = [super init]) != nil) {
		data = aData;
		ptr = [data bytes];
		length = left = [data length];
	}
	return self;
}

- (ViStreamBuffer *)initWithBuffer:(const void *)buffer length:(NSUInteger)aLength
{
	if ((self = [super init]) != nil) {
		ptr = buffer;
		length = left = aLength;
	}
	return self;
}

- (void)setConsumed:(NSUInteger)size
{
	ptr += size;
	left -= size;
	DEBUG(@"consumed %lu bytes of buffer, %lu bytes left", size, left);
}

@end

#pragma mark -

@implementation ViBufferedStream

- (void)read
{
	DEBUG(@"reading on fd %d", fd_in);

	buflen = 0;
	ssize_t ret = read(fd_in, buffer, sizeof(buffer));
	if (ret <= 0) {
		if (ret == 0) {
			DEBUG(@"read EOF from fd %d", fd_in);
			if ([[self delegate] respondsToSelector:@selector(stream:handleEvent:)])
				[[self delegate] stream:self handleEvent:NSStreamEventEndEncountered];
		} else {
			INFO(@"read(%d) failed: %s", fd_in, strerror(errno));
			if ([[self delegate] respondsToSelector:@selector(stream:handleEvent:)])
				[[self delegate] stream:self handleEvent:NSStreamEventErrorOccurred];
		}
		[self shutdownRead];
	} else {
		DEBUG(@"read %zi bytes from fd %i", ret, fd_in);
		buflen = ret;
		if ([[self delegate] respondsToSelector:@selector(stream:handleEvent:)])
			[[self delegate] stream:self handleEvent:NSStreamEventHasBytesAvailable];
	}
}

- (void)drain:(NSUInteger)size
{
	ViStreamBuffer *buf;

	DEBUG(@"draining %lu bytes", size);

	while (size > 0 && (buf = [outputBuffers objectAtIndex:0]) != nil) {
		if (size >= buf.length) {
			size -= buf.length;
			[outputBuffers removeObjectAtIndex:0];
		} else {
			[buf setConsumed:size];
			break;
		}
	}
}

void	 hexdump(void *data, size_t len, const char *fmt, ...);

- (int)flush
{
	struct iovec	 iov[IOV_MAX];
	unsigned int	 i = 0;
	ssize_t		 n;
	NSUInteger tot = 0;

	for (ViStreamBuffer *buf in outputBuffers) {
		if (i >= IOV_MAX)
			break;
		iov[i].iov_base = (void *)buf.ptr;
		iov[i].iov_len = buf.left;
		tot += buf.left;
		i++;

		hexdump(buf.ptr, buf.left, "enqueueing buffer:");
	}

	if (tot == 0)
		return 0;

	DEBUG(@"flushing %i buffers, total %lu bytes", i, tot);

	if ((n = writev(fd_out, iov, i)) == -1) {
		if (errno == EAGAIN || errno == ENOBUFS ||
		    errno == EINTR)	/* try later */
			return 0;
		else
			return -1;
	}

	DEBUG(@"writev(%d) returned %zi", fd_out, n);

	if (n == 0) {			/* connection closed */
		errno = 0;
		return -2;
	}

	[self drain:n];

	if ([outputBuffers count] == 0)
		return 0;

	CFSocketEnableCallBacks(outputSocket, kCFSocketWriteCallBack);
	return 1;
}

static void
fd_read(CFSocketRef s,
	CFSocketCallBackType callbackType,
	CFDataRef address,
	const void *data,
	void *info)
{
	ViBufferedStream *stream = info;
	[stream read];
}

static void
fd_write(CFSocketRef s,
	 CFSocketCallBackType callbackType,
	 CFDataRef address,
	 const void *data,
	 void *info)
{
	ViBufferedStream *stream = info;

	int ret = [stream flush];
	if (ret == 0) { /* all output buffers flushed to socket */
		if ([[stream delegate] respondsToSelector:@selector(stream:handleEvent:)])
			[[stream delegate] stream:stream handleEvent:NSStreamEventHasSpaceAvailable];
	} else if (ret == -1) {
		if ([[stream delegate] respondsToSelector:@selector(stream:handleEvent:)])
			[[stream delegate] stream:stream handleEvent:NSStreamEventErrorOccurred];
		[stream shutdownWrite];
	} else if (ret == -2) {
		if ([[stream delegate] respondsToSelector:@selector(stream:handleEvent:)])
			[[stream delegate] stream:stream handleEvent:NSStreamEventEndEncountered];
		[stream shutdownWrite];
	}
}

- (id)initWithReadFileDescriptor:(int)read_fd
	     writeFileDescriptor:(int)write_fd
{
	DEBUG(@"init with read fd %d, write fd %d", read_fd, write_fd);

	if ((self = [super init]) != nil) {
		fd_in = read_fd;
		fd_out = write_fd;

		outputBuffers = [NSMutableArray array];

		int flags = fcntl(fd_in, F_GETFL, 0);
		fcntl(fd_in, F_SETFL, flags | O_NONBLOCK);
		flags = fcntl(fd_out, F_GETFL, 0);
		fcntl(fd_out, F_SETFL, flags | O_NONBLOCK);

		inputContext.version = 0;
		inputContext.info = self; /* user data passed to the callbacks */
		inputContext.retain = NULL;
		inputContext.release = NULL;
		inputContext.copyDescription = NULL;

		inputSocket = CFSocketCreateWithNative(
			kCFAllocatorDefault,
			fd_in,
			kCFSocketReadCallBack,
			fd_read,
			&inputContext);
		if (inputSocket == NULL) {
			INFO(@"failed to create input CFSocket of fd %i", fd_in);
			return nil;
		}
		inputSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, inputSocket, 0);
		INFO(@"created input source %@", inputSource);

		outputContext.version = 0;
		outputContext.info = self; /* user data passed to the callbacks */
		outputContext.retain = NULL;
		outputContext.release = NULL;
		outputContext.copyDescription = NULL;

		outputSocket = CFSocketCreateWithNative(
			kCFAllocatorDefault,
			fd_out,
			kCFSocketWriteCallBack,
			fd_write,
			&outputContext);
		if (outputSocket == NULL) {
			INFO(@"failed to create output CFSocket of fd %i", fd_out);
			return nil;
		}
		outputSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, outputSocket, 0);
		INFO(@"created output source %@", outputSource);


		CFSocketEnableCallBacks(inputSocket, kCFSocketReadCallBack);
	}
	return self;
}

- (id)initWithTask:(NSTask *)task
{
	NSPipe *stdin = [task standardInput];
	NSPipe *stdout = [task standardOutput];
	if (![stdin isKindOfClass:[NSPipe class]] || ![stdout isKindOfClass:[NSPipe class]])
		return nil;
	return [self initWithReadFileDescriptor:[[stdout fileHandleForReading] fileDescriptor]
			    writeFileDescriptor:[[stdin fileHandleForWriting] fileDescriptor]];
}

- (void)open
{
	INFO(@"%s", "open?");
}

- (void)shutdownWrite
{
	if (fd_out >= 0) {
		INFO(@"shutting down write pipe %d", fd_out);
		if (runLoopMode)
			CFRunLoopRemoveSource(CFRunLoopGetCurrent(), outputSource, (CFStringRef)runLoopMode);
		CFSocketInvalidate(outputSocket);
		outputSocket = NULL;
		close(fd_out);
		fd_out = -1;
	}
}

- (void)shutdownRead
{
	if (fd_in >= 0) {
		INFO(@"shutting down read pipe %d", fd_in);
		if (runLoopMode)
			CFRunLoopRemoveSource(CFRunLoopGetCurrent(), inputSource, (CFStringRef)runLoopMode);
		CFSocketInvalidate(inputSocket);
		inputSocket = NULL;
		close(fd_in);
		fd_in = -1;
	}
}

- (void)close
{
	[self shutdownRead];
	[self shutdownWrite];
}

- (void)scheduleInRunLoop:(NSRunLoop *)aRunLoop forMode:(NSString *)mode
{
	INFO(@"adding to mode %@", mode);
	if (fd_in >= 0)
		CFRunLoopAddSource(CFRunLoopGetCurrent(), inputSource, (CFStringRef)mode);
	if (fd_out >= 0)
		CFRunLoopAddSource(CFRunLoopGetCurrent(), outputSource, (CFStringRef)mode);
	runLoopMode = mode;
}

- (void)removeFromRunLoop:(NSRunLoop *)aRunLoop forMode:(NSString *)mode
{
	INFO(@"removing from mode %@", mode);
	if (fd_in >= 0)
		CFRunLoopRemoveSource(CFRunLoopGetCurrent(), inputSource, (CFStringRef)mode);
	if (fd_out >= 0)
		CFRunLoopRemoveSource(CFRunLoopGetCurrent(), outputSource, (CFStringRef)mode);
	runLoopMode = nil;
}

- (BOOL)getBuffer:(const void **)buf length:(NSUInteger *)len
{
	*buf = buffer;
	*len = buflen;
	return YES;
}

- (BOOL)hasBytesAvailable
{
	return buflen > 0;
}

- (BOOL)hasSpaceAvailable
{
	return YES;
}

- (void)write:(const void *)buf length:(NSUInteger)length
{
	INFO(@"enqueueing %lu bytes", length);
	[outputBuffers addObject:[[ViStreamBuffer alloc] initWithBuffer:buf length:length]];
	CFSocketEnableCallBacks(outputSocket, kCFSocketWriteCallBack);
}

- (void)writeData:(NSData *)data
{
	if ([data length] > 0) {
		INFO(@"enqueueing %lu bytes", [data length]);
		[outputBuffers addObject:[[ViStreamBuffer alloc] initWithData:data]];
		CFSocketEnableCallBacks(outputSocket, kCFSocketWriteCallBack);
	}
}

- (void)setDelegate:(id<NSStreamDelegate>)aDelegate
{
	delegate = aDelegate;
}

- (id<NSStreamDelegate>)delegate
{
	return delegate;
}

- (id)propertyForKey:(NSString *)key
{
	INFO(@"key is %@", key);
	return nil;
}

- (BOOL)setProperty:(id)property forKey:(NSString *)key
{
	INFO(@"key is %@", key);
	return NO;
}

- (NSStreamStatus)streamStatus
{
	INFO(@"returning %d", NSStreamStatusOpen);
	return NSStreamStatusOpen;
}

- (NSError *)streamError
{
	INFO(@"%s", "returning nil");
	return nil;
}

@end