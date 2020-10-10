//
//  LeftRightAnimation.swift
//  SwiftMessages
//
//  Created by cddjr on 2020/10/9.
//  Copyright © 2020 SwiftKick Mobile. All rights reserved.
//

import UIKit

public class LeftRightAnimation: NSObject, Animator {

    public enum Style {
        case left
        case right
    }

    public weak var delegate: AnimationDelegate?

    public let style: Style

    open var showDuration: TimeInterval = 0.4

    open var hideDuration: TimeInterval = 0.2

    open var springDamping: CGFloat = 0.8

    open var closeSpeedThreshold: CGFloat = 750.0;

    open var closePercentThreshold: CGFloat = 0.33;

    open var closeAbsoluteThreshold: CGFloat = 75.0;

    public private(set) lazy var panGestureRecognizer: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer()
        pan.addTarget(self, action: #selector(pan(_:)))
        return pan
    }()

    weak var messageView: UIView?
    weak var containerView: UIView?
    var context: AnimationContext?

    public init(style: Style) {
        self.style = style
    }

    init(style: Style, delegate: AnimationDelegate) {
        self.style = style
        self.delegate = delegate
    }

    public func show(context: AnimationContext, completion: @escaping AnimationCompletion) {
        NotificationCenter.default.addObserver(self, selector: #selector(adjustMargins), name: UIDevice.orientationDidChangeNotification, object: nil)
        install(context: context)
        showAnimation(completion: completion)
    }

    public func hide(context: AnimationContext, completion: @escaping AnimationCompletion) {
        NotificationCenter.default.removeObserver(self)
        let view = context.messageView
        self.context = context
        UIView.animate(withDuration: hideDuration, delay: 0, options: [.beginFromCurrentState, .curveEaseIn], animations: {
            switch self.style {
            case .left:
                view.transform = CGAffineTransform(translationX: -view.frame.width, y: 0)
            case .right:
                view.transform = CGAffineTransform(translationX: view.frame.maxX + view.frame.width, y: 0)
            }
        }, completion: { completed in
            #if SWIFTMESSAGES_APP_EXTENSIONS
            completion(completed)
            #else
            // Fix #131 by always completing if application isn't active.
            completion(completed || UIApplication.shared.applicationState != .active)
            #endif
        })
    }

    func install(context: AnimationContext) {
        let view = context.messageView
        let container = context.containerView
        messageView = view
        containerView = container
        self.context = context
        if let adjustable = context.messageView as? MarginAdjustable {
            bounceOffset = adjustable.bounceAnimationOffset
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        view.topAnchor.constraint(equalTo: container.topAnchor).isActive = true
        view.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true
        switch style {
        case .left:
            view.leftAnchor.constraint(equalTo: container.leftAnchor, constant: -bounceOffset).with(priority: UILayoutPriority(200)).isActive = true
        case .right:
            view.rightAnchor.constraint(equalTo: container.rightAnchor, constant: bounceOffset).with(priority: UILayoutPriority(200)).isActive = true
        }
        // Important to layout now in order to get the right safe area insets
        container.layoutIfNeeded()
        adjustMargins()
        container.layoutIfNeeded()
        let animationDistance = view.frame.width
        switch style {
        case .left:
            view.transform = CGAffineTransform(translationX: -animationDistance, y: 0)
        case .right:
            view.transform = CGAffineTransform(translationX: animationDistance, y: 0)
        }
        if context.interactiveHide {
            if let view = view as? BackgroundViewable {
                view.backgroundView.addGestureRecognizer(panGestureRecognizer)
            } else {
                view.addGestureRecognizer(panGestureRecognizer)
            }
        }
        if let view = view as? BackgroundViewable,
            let cornerRoundingView = view.backgroundView as? CornerRoundingView,
            cornerRoundingView.roundsLeadingCorners {
            switch style {
            case .left:
                cornerRoundingView.roundedCorners = [.topRight, .bottomRight]
            case .right:
                cornerRoundingView.roundedCorners = [.topLeft, .bottomLeft]
            }
        }
    }

    @objc public func adjustMargins() {
        guard let adjustable = messageView as? MarginAdjustable & UIView,
            let context = context else { return }
        adjustable.preservesSuperviewLayoutMargins = false
        if #available(iOS 11, *) {
            adjustable.insetsLayoutMarginsFromSafeArea = false
        }
        var layoutMargins = adjustable.defaultMarginAdjustment(context: context)
        switch style {
        case .left:
            layoutMargins.left += bounceOffset
        case .right:
            layoutMargins.right += bounceOffset
        }
        adjustable.layoutMargins = layoutMargins
    }

    func showAnimation(completion: @escaping AnimationCompletion) {
        guard let view = messageView else {
            completion(false)
            return
        }
        let animationDistance = abs(view.transform.tx)
        // Cap the initial velocity at zero because the bounceOffset may not be great
        // enough to allow for greater bounce induced by a quick panning motion.
        let initialSpringVelocity = animationDistance == 0.0 ? 0.0 : min(0.0, closeSpeed / animationDistance)
        UIView.animate(withDuration: showDuration, delay: 0.0, usingSpringWithDamping: springDamping, initialSpringVelocity: initialSpringVelocity, options: [.beginFromCurrentState, .curveLinear, .allowUserInteraction], animations: {
            view.transform = .identity
        }, completion: { completed in
            // Fix #131 by always completing if application isn't active.
            #if SWIFTMESSAGES_APP_EXTENSIONS
            completion(completed)
            #else
            completion(completed || UIApplication.shared.applicationState != .active)
            #endif
        })
    }

    fileprivate var bounceOffset: CGFloat = 5

    /*
     MARK: - Pan to close
     */

    fileprivate var closing = false
    fileprivate var rubberBanding = false
    fileprivate var closeSpeed: CGFloat = 0.0
    fileprivate var closePercent: CGFloat = 0.0
    fileprivate var panTranslationX: CGFloat = 0.0

    @objc func pan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .changed:
            guard let view = messageView else { return }
            let width = view.bounds.width - bounceOffset
            if width <= 0 { return }
            var velocity = pan.velocity(in: view)
            var translation = pan.translation(in: view)
            if case .left = style {
                velocity.x *= -1.0
                translation.x *= -1.0
            }
            var translationAmount = translation.x >= 0 ? translation.x : -pow(abs(translation.x), 0.7)
            if !closing {
                // Turn on rubber banding if background view is inset from message view.
                if let background = (messageView as? BackgroundViewable)?.backgroundView, background != view {
                    switch style {
                    case .left:
                        rubberBanding = background.frame.minX > 0
                    case .right:
                        rubberBanding = background.frame.maxX < view.bounds.width
                    }
                }
                if !rubberBanding && translationAmount < 0 { return }
                closing = true
                delegate?.panStarted(animator: self)
            }
            if !rubberBanding && translationAmount < 0 { translationAmount = 0 }
            switch style {
            case .left:
                view.transform = CGAffineTransform(translationX: -translationAmount, y: 0)
            case .right:
                view.transform = CGAffineTransform(translationX: translationAmount, y: 0)
            }
            closeSpeed = velocity.x
            closePercent = translation.x / width
            panTranslationX = translation.x
        case .ended, .cancelled:
            if closeSpeed > closeSpeedThreshold || closePercent > closePercentThreshold || panTranslationX > closeAbsoluteThreshold {
                delegate?.hide(animator: self)
            } else {
                closing = false
                rubberBanding = false
                closeSpeed = 0.0
                closePercent = 0.0
                panTranslationX = 0.0
                showAnimation(completion: { (completed) in
                    self.delegate?.panEnded(animator: self)
                })
            }
        default:
            break
        }
    }
}
