// 16Player remake for iOS 12.
// Replaces the lock screen Now Playing controls with a custom iOS 16 style card.
// Data and controls go through MediaRemote (private), loaded at runtime.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>

// ---------------------------------------------------------------- MediaRemote
typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef Boolean (*MRSendFn)(uint32_t, CFDictionaryRef);
typedef void (*MRRegFn)(dispatch_queue_t);

static MRGetInfoFn gGetInfo = NULL;
static MRSendFn gSend = NULL;

static void loadMR(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (!h) return;
        gGetInfo = (MRGetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
        gSend = (MRSendFn)dlsym(h, "MRMediaRemoteSendCommand");
        MRRegFn reg = (MRRegFn)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
        if (reg) reg(dispatch_get_main_queue());
    });
}

static NSString *fmtTime(double s) {
    if (!isfinite(s) || s < 0) s = 0;
    int t = (int)s;
    return [NSString stringWithFormat:@"%d:%02d", t / 60, t % 60];
}

static void dbg(NSString *line) {
    NSString *path = @"/var/mobile/sixteenplayer-debug.txt";
    NSString *str = [line stringByAppendingString:@"\n"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [str writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[str dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static BOOL containsClass(UIView *v, Class c) {
    if ([v isKindOfClass:c]) return YES;
    for (UIView *s in v.subviews) if (containsClass(s, c)) return YES;
    return NO;
}

// Lowest ancestor of the controls that also contains the song header.
static UIView *panelRoot(UIView *container, Class headerCls) {
    for (UIView *v = container.superview; v; v = v.superview) {
        if (containsClass(v, headerCls)) return v;
    }
    return nil;
}

// ---------------------------------------------------------------- Glyphs
typedef NS_ENUM(NSInteger, SPGlyphType) {
    SPGlyphPrev, SPGlyphPlay, SPGlyphPause, SPGlyphNext,
    SPGlyphStar, SPGlyphStarFilled, SPGlyphAirPlay, SPGlyphWave
};

@interface SPGlyph : UIView
@property (nonatomic) SPGlyphType type;
@end

@implementation SPGlyph
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = NO;
    }
    return self;
}
- (void)setType:(SPGlyphType)t {
    _type = t;
    [self setNeedsDisplay];
}
static void addTri(UIBezierPath *p, CGFloat x0, CGFloat x1, CGFloat h, BOOL left) {
    if (left) {
        [p moveToPoint:CGPointMake(x1, 0)];
        [p addLineToPoint:CGPointMake(x0, h / 2)];
        [p addLineToPoint:CGPointMake(x1, h)];
    } else {
        [p moveToPoint:CGPointMake(x0, 0)];
        [p addLineToPoint:CGPointMake(x1, h / 2)];
        [p addLineToPoint:CGPointMake(x0, h)];
    }
    [p closePath];
}
- (void)drawRect:(CGRect)rect {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    UIColor *white = [UIColor whiteColor];
    [white setFill];
    [white setStroke];
    UIBezierPath *p = [UIBezierPath bezierPath];
    p.lineJoinStyle = kCGLineJoinRound;
    p.lineWidth = 2.0;

    switch (_type) {
        case SPGlyphPrev:
            addTri(p, 0, w * 0.52, h, YES);
            addTri(p, w * 0.48, w, h, YES);
            [p fill]; [p stroke];
            break;
        case SPGlyphNext:
            addTri(p, 0, w * 0.52, h, NO);
            addTri(p, w * 0.48, w, h, NO);
            [p fill]; [p stroke];
            break;
        case SPGlyphPlay:
            [p moveToPoint:CGPointMake(w * 0.18, 0)];
            [p addLineToPoint:CGPointMake(w * 0.18, h)];
            [p addLineToPoint:CGPointMake(w, h / 2)];
            [p closePath];
            [p fill]; [p stroke];
            break;
        case SPGlyphPause: {
            UIBezierPath *a = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(w * 0.10, 0, w * 0.32, h) cornerRadius:2.5];
            UIBezierPath *b = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(w * 0.58, 0, w * 0.32, h) cornerRadius:2.5];
            [a fill]; [b fill];
            break;
        }
        case SPGlyphStar:
        case SPGlyphStarFilled: {
            CGPoint c = CGPointMake(w / 2, h / 2 + h * 0.03);
            CGFloat R = MIN(w, h) / 2 * 0.95, r = R * 0.42;
            for (int i = 0; i < 10; i++) {
                CGFloat ang = -M_PI / 2 + i * M_PI / 5;
                CGFloat rad = (i % 2 == 0) ? R : r;
                CGPoint pt = CGPointMake(c.x + cos(ang) * rad, c.y + sin(ang) * rad);
                if (i == 0) [p moveToPoint:pt]; else [p addLineToPoint:pt];
            }
            [p closePath];
            p.lineWidth = 1.6;
            if (_type == SPGlyphStarFilled) [p fill];
            [p stroke];
            break;
        }
        case SPGlyphAirPlay: {
            CGPoint c = CGPointMake(w / 2, h * 0.52);
            UIBezierPath *a1 = [UIBezierPath bezierPathWithArcCenter:c radius:w * 0.48 startAngle:M_PI * 0.85 endAngle:M_PI * 2.15 clockwise:YES];
            a1.lineWidth = 1.8; [a1 stroke];
            UIBezierPath *a2 = [UIBezierPath bezierPathWithArcCenter:c radius:w * 0.30 startAngle:M_PI * 0.85 endAngle:M_PI * 2.15 clockwise:YES];
            a2.lineWidth = 1.8; [a2 stroke];
            [p moveToPoint:CGPointMake(w * 0.22, h)];
            [p addLineToPoint:CGPointMake(w * 0.78, h)];
            [p addLineToPoint:CGPointMake(w / 2, h * 0.64)];
            [p closePath];
            [p fill];
            break;
        }
        case SPGlyphWave: {
            CGFloat hs[5] = {0.35, 0.65, 1.0, 0.65, 0.35};
            CGFloat bw = w / 9.0;
            for (int i = 0; i < 5; i++) {
                CGFloat bh = h * hs[i];
                CGRect r = CGRectMake(i * bw * 2, (h - bh) / 2, bw, bh);
                [[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:bw / 2] fill];
            }
            break;
        }
    }
}
@end

// ---------------------------------------------------------------- Player card
static UILabel *mkLabel(CGFloat size, UIFontWeight weight, CGFloat alpha, NSTextAlignment al) {
    UILabel *l = [[UILabel alloc] init];
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = [UIColor colorWithWhite:1 alpha:alpha];
    l.textAlignment = al;
    l.backgroundColor = [UIColor clearColor];
    return l;
}

@interface SPPlayerView : UIView
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UILabel *elapsedLabel;
@property (nonatomic, strong) UILabel *remainingLabel;
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) UIView *fill;
@property (nonatomic, strong) SPGlyph *prevG;
@property (nonatomic, strong) SPGlyph *playG;
@property (nonatomic, strong) SPGlyph *nextG;
@property (nonatomic, strong) SPGlyph *starG;
@property (nonatomic, strong) SPGlyph *airG;
@property (nonatomic, strong) SPGlyph *waveG;
@property (nonatomic, strong) UIButton *prevB;
@property (nonatomic, strong) UIButton *playB;
@property (nonatomic, strong) UIButton *nextB;
@property (nonatomic, strong) UIButton *starB;
@property (nonatomic) double elapsed;
@property (nonatomic) double duration;
@property (nonatomic) double rate;
@property (nonatomic) BOOL playing;
@property (nonatomic) BOOL starred;
@property (nonatomic, strong) NSDate *stamp;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) int ticks;
@property (nonatomic, weak) UIView *host;
@end

@implementation SPPlayerView

- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (!self) return nil;

    self.clipsToBounds = YES;
    self.layer.cornerRadius = 22.0;
    self.layer.borderWidth = 0.6;
    self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;

    _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    [self addSubview:_blur];

    _titleLabel = mkLabel(15, UIFontWeightSemibold, 1.0, NSTextAlignmentCenter);
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.text = @"Not Playing";
    [self addSubview:_titleLabel];

    _artistLabel = mkLabel(15, UIFontWeightRegular, 0.55, NSTextAlignmentCenter);
    _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_artistLabel];

    _elapsedLabel = mkLabel(9, UIFontWeightMedium, 0.55, NSTextAlignmentLeft);
    _elapsedLabel.text = @"0:00";
    [self addSubview:_elapsedLabel];
    _remainingLabel = mkLabel(9, UIFontWeightMedium, 0.55, NSTextAlignmentRight);
    _remainingLabel.text = @"-0:00";
    [self addSubview:_remainingLabel];

    _track = [[UIView alloc] init];
    _track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.28];
    _track.layer.cornerRadius = 2.0;
    _track.clipsToBounds = YES;
    [self addSubview:_track];
    _fill = [[UIView alloc] init];
    _fill.backgroundColor = [UIColor whiteColor];
    [_track addSubview:_fill];

    _starG = [[SPGlyph alloc] init]; _starG.type = SPGlyphStar; _starG.alpha = 0.6;
    _prevG = [[SPGlyph alloc] init]; _prevG.type = SPGlyphPrev;
    _playG = [[SPGlyph alloc] init]; _playG.type = SPGlyphPlay;
    _nextG = [[SPGlyph alloc] init]; _nextG.type = SPGlyphNext;
    _airG = [[SPGlyph alloc] init]; _airG.type = SPGlyphAirPlay; _airG.alpha = 0.6;
    _waveG = [[SPGlyph alloc] init]; _waveG.type = SPGlyphWave; _waveG.alpha = 0.45;
    for (SPGlyph *g in @[_starG, _prevG, _playG, _nextG, _airG, _waveG]) [self addSubview:g];

    _prevB = [UIButton buttonWithType:UIButtonTypeCustom];
    [_prevB addTarget:self action:@selector(tapPrev) forControlEvents:UIControlEventTouchUpInside];
    _playB = [UIButton buttonWithType:UIButtonTypeCustom];
    [_playB addTarget:self action:@selector(tapPlay) forControlEvents:UIControlEventTouchUpInside];
    _nextB = [UIButton buttonWithType:UIButtonTypeCustom];
    [_nextB addTarget:self action:@selector(tapNext) forControlEvents:UIControlEventTouchUpInside];
    _starB = [UIButton buttonWithType:UIButtonTypeCustom];
    [_starB addTarget:self action:@selector(tapStar) forControlEvents:UIControlEventTouchUpInside];
    for (UIButton *b in @[_prevB, _playB, _nextB, _starB]) [self addSubview:b];

    NSArray *names = @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                       @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                       @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"];
    for (NSString *n in names) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:n object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_timer invalidate];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self.timer invalidate];
    self.timer = nil;
    if (self.window) {
        __weak SPPlayerView *ws = self;
        self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            [ws tick];
        }];
        [self refresh];
    }
}

- (void)tick {
    UIView *h = self.host;
    self.hidden = !(h && h.window && !h.hidden);
    self.ticks++;
    if (self.ticks % 6 == 0) [self refresh];
    [self updateProgress];
}

- (void)refresh {
    loadMR();
    if (!gGetInfo) return;
    __weak SPPlayerView *ws = self;
    gGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
        SPPlayerView *s = ws;
        if (!s) return;
        NSDictionary *d = (__bridge NSDictionary *)info;
        NSString *title = d[@"kMRMediaRemoteNowPlayingInfoTitle"];
        NSString *artist = d[@"kMRMediaRemoteNowPlayingInfoArtist"];
        s.titleLabel.text = title.length ? title : @"Not Playing";
        s.artistLabel.text = artist ?: @"";
        s.duration = [d[@"kMRMediaRemoteNowPlayingInfoDuration"] doubleValue];
        s.elapsed = [d[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
        s.rate = [d[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] doubleValue];
        NSDate *ts = d[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        s.stamp = ts ?: [NSDate date];
        s.playing = s.rate > 0.01;
        s.playG.type = s.playing ? SPGlyphPause : SPGlyphPlay;
        [s updateProgress];
    });
}

- (void)updateProgress {
    double cur = self.elapsed;
    if (self.playing && self.stamp) cur += self.rate * [[NSDate date] timeIntervalSinceDate:self.stamp];
    if (cur < 0) cur = 0;
    if (self.duration > 0 && cur > self.duration) cur = self.duration;
    double p = self.duration > 0 ? cur / self.duration : 0;
    self.elapsedLabel.text = fmtTime(cur);
    self.remainingLabel.text = [@"-" stringByAppendingString:fmtTime(MAX(0, self.duration - cur))];
    self.fill.frame = CGRectMake(0, 0, self.track.bounds.size.width * p, self.track.bounds.size.height);
}

- (void)send:(uint32_t)cmd {
    loadMR();
    if (gSend) gSend(cmd, NULL);
    [self performSelector:@selector(refresh) withObject:nil afterDelay:0.35];
}
- (void)tapPrev { [self send:5]; }
- (void)tapPlay { [self send:2]; }
- (void)tapNext { [self send:4]; }
- (void)tapStar {
    // Visual only: iOS 12 has no public favourite command.
    self.starred = !self.starred;
    self.starG.type = self.starred ? SPGlyphStarFilled : SPGlyphStar;
    self.starG.alpha = self.starred ? 1.0 : 0.6;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    self.blur.frame = self.bounds;

    // Positions are fractions measured from the reference screenshot.
    CGFloat textW = W * 0.72;
    self.titleLabel.frame = CGRectMake((W - textW) / 2, H * 0.16 - 10, textW, 20);
    self.artistLabel.frame = CGRectMake((W - textW) / 2, H * 0.31 - 10, textW, 20);

    CGFloat barY = H * 0.48;
    self.elapsedLabel.frame = CGRectMake(W * 0.025, barY - 7, W * 0.105, 14);
    self.track.frame = CGRectMake(W * 0.134, barY - 1.5, W * 0.718, 3);
    self.remainingLabel.frame = CGRectMake(W * 0.862, barY - 7, W * 0.12, 14);

    CGFloat cy = H * 0.76;
    CGFloat gh = MIN(34.0, H * 0.24);
    self.playG.frame = CGRectMake(W * 0.498 - gh * 0.45, cy - gh / 2, gh * 0.9, gh);
    CGFloat sw = W * 0.095, sh = MIN(24.0, H * 0.15);
    self.prevG.frame = CGRectMake(W * 0.294 - sw / 2, cy - sh / 2, sw, sh);
    self.nextG.frame = CGRectMake(W * 0.700 - sw / 2, cy - sh / 2, sw, sh);
    self.starG.frame = CGRectMake(W * 0.088 - 11, cy - 11, 22, 22);
    self.airG.frame = CGRectMake(W * 0.912 - 11, cy - 11, 22, 22);
    self.waveG.frame = CGRectMake(W * 0.915 - 8, H * 0.175 - 5, 16, 10);

    self.playB.frame = CGRectMake(W * 0.498 - 28, cy - 28, 56, 56);
    self.prevB.frame = CGRectMake(W * 0.294 - 28, cy - 28, 56, 56);
    self.nextB.frame = CGRectMake(W * 0.700 - 28, cy - 28, 56, 56);
    self.starB.frame = CGRectMake(W * 0.088 - 22, cy - 22, 44, 44);

    [self updateProgress];
}
@end

// ---------------------------------------------------------------- Hook
@interface MediaControlsContainerView : UIView @end

static void installPlayer(UIView *container) {
    Class hc = NSClassFromString(@"MediaControlsHeaderView");
    if (!hc || !container.window) return;

    // Skip Control Center: only the lock screen player gets replaced.
    NSMutableString *chain = [NSMutableString string];
    BOOL cc = NO;
    for (UIView *v = container; v; v = v.superview) {
        NSString *n = NSStringFromClass([v class]);
        [chain appendFormat:@"%@ > ", n];
        if ([n containsString:@"CCUI"]) cc = YES;
    }
    static int logged = 0;
    if (logged < 3) {
        logged++;
        dbg([NSString stringWithFormat:@"chain(cc=%d): %@", cc, chain]);
    }
    if (cc) return;

    CGRect scr = [UIScreen mainScreen].bounds;
    UIView *host = panelRoot(container, hc);
    if (!host || host.bounds.size.height > scr.size.height * 0.6) {
        static int failed = 0;
        if (failed < 3) {
            failed++;
            dbg([NSString stringWithFormat:@"no usable panel root (host=%@ h=%.0f)",
                 host ? NSStringFromClass([host class]) : @"nil", host ? host.bounds.size.height : 0]);
        }
        return;
    }

    // Put the card on the lock screen's main page (it moves with page swipes).
    // Never attach to a scroll view or collection view: they scroll and clip it.
    UIView *anc = nil;
    for (UIView *v = host.superview; v && ![v isKindOfClass:[UIWindow class]]; v = v.superview) {
        if ([NSStringFromClass([v class]) isEqualToString:@"SBDashBoardMainPageView"]) { anc = v; break; }
    }
    if (!anc) {
        for (UIView *v = host.superview; v && ![v isKindOfClass:[UIWindow class]]; v = v.superview) {
            if ([v isKindOfClass:[UIScrollView class]]) continue;
            if (fabs(v.bounds.size.width - scr.size.width) < 2 &&
                fabs(v.bounds.size.height - scr.size.height) < 2) { anc = v; break; }
        }
    }
    if (!anc) return;

    // Hide the stock player's gray platter so only our card is left.
    UIView *item = nil, *platter = nil;
    for (UIView *v = host.superview; v && ![v isKindOfClass:[UIWindow class]]; v = v.superview) {
        NSString *n = NSStringFromClass([v class]);
        if (!item && [n isEqualToString:@"SBDashBoardAdjunctItemView"]) item = v;
        if (!platter && [n isEqualToString:@"SBDashBoardAdjunctItemPlatterView"]) platter = v;
    }
    UIView *toHide = item ?: platter;
    if (toHide) toHide.hidden = YES;

    // Card position copied from the reference: near the bottom, just above the buttons.
    CGFloat m = scr.size.width * 0.022;
    CGFloat w = scr.size.width - 2 * m;
    CGFloat h = w / 2.79;
    CGFloat bottom = scr.size.height * 0.825;
    CGRect target = CGRectMake(m, bottom - h, w, h);

    SPPlayerView *pv = (SPPlayerView *)[anc viewWithTag:2650];
    if (!pv) {
        pv = [[SPPlayerView alloc] initWithFrame:target];
        pv.tag = 2650;
        [anc addSubview:pv];
        dbg([NSString stringWithFormat:@"installed card in %@ (host %@)", NSStringFromClass([anc class]), NSStringFromClass([host class])]);
    }
    pv.host = host;
    pv.frame = target;
    pv.hidden = NO;
    for (UIView *s in host.subviews) s.hidden = YES;
    [anc bringSubviewToFront:pv];
}

%hook MediaControlsContainerView
- (void)layoutSubviews {
    %orig;
    installPlayer(self);
}
%end

%ctor {
    dbg([NSString stringWithFormat:@"loaded in %@: container=%d header=%d panel=%d",
         [[NSBundle mainBundle] bundleIdentifier],
         NSClassFromString(@"MediaControlsContainerView") != nil,
         NSClassFromString(@"MediaControlsHeaderView") != nil,
         NSClassFromString(@"MediaControlsPanelViewController") != nil]);
    if (NSClassFromString(@"MediaControlsContainerView")) {
        %init;
    }
}
