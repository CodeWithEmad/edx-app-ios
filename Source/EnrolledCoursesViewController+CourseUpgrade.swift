//
//  EnrolledCoursesViewController+CourseUpgrade.swift
//  edX
//
//  Created by Saeed Bashir on 4/27/22.
//  Copyright © 2022 edX. All rights reserved.
//

import Foundation

extension EnrolledCoursesViewController {
    func handleCourseUpgrade() {
        guard let _ = courseUpgradeHelper.courseUpgradeModel
            else { return }

        environment.dataManager.enrollmentManager.forceReload()
    }

    func navigateToScreenAterCourseUpgrade() {
        guard let courseUpgradeModel = courseUpgradeHelper.courseUpgradeModel
        else { return }
        
        if courseUpgradeModel.screen == .courseDashboard || courseUpgradeModel.screen == .courseComponent {
            dismiss() { [weak self] _ in
                self?.navigationController?.popToViewController(of: LearnContainerViewController.self, animated: true) { [weak self] in
                    guard let weakSelf = self else { return }
                    weakSelf.environment.router?.showCourseWithID(courseID: courseUpgradeModel.courseID, fromController: weakSelf, animated: true)
                }
            }
        } else {
            courseUpgradeHelper.removeLoader()
        }
    }
    
    private func dismiss(completion: @escaping (Bool) -> Void) {
        if let rootController = UIApplication.shared.window?.rootViewController, rootController.presentedViewController != nil {
            rootController.dismiss(animated: false) {
                completion(true)
            }
        } else {
            completion(true)
        }
    }

    func resolveUnfinishedPaymentIfRequired() {
        guard var skus = courseUpgradeHelper.savedUnfinishedIAPSKUsForCurrentUser(),
              !skus.isEmpty && PaymentManager.shared.unfinishedPurchases else { return }

        // fulfill outside fullfilled payments, marked complete bby support team
        let verifiedEnrollments = environment.interface?.courses?.filter({ $0.type == .verified}) ?? []
        for enrollment in verifiedEnrollments {
            if let courseSku = enrollment.course.sku, skus.contains(courseSku) {
                // Payment was fullfilled outside the app
                PaymentManager.shared.markPurchaseComplete(courseSku, type: .transction)
                courseUpgradeHelper.markIAPSKUCompleteInKeychain(courseSku)
                skus.removeAll(where: { $0 == courseSku })
            }
        }

        // unresolved payments fulfilled outside the app by support team
        if !PaymentManager.shared.unfinishedPurchases || skus.isEmpty {
            return
        }

        resolveUnfinishedPayments()
    }

    private func resolveUnfinishedPayments() {
        guard let skus = courseUpgradeHelper.savedUnfinishedIAPSKUsForCurrentUser(),
              !skus.isEmpty && PaymentManager.shared.unfinishedPurchases else { return }

        let unfinishedPurchases = PaymentManager.shared.unfinishedProductIDs
        var resolveAbleSkus: [String] = []

        for productID in unfinishedPurchases {
            if skus.contains(productID) {
                resolveAbleSkus.append(productID)
            }
            else {
                PaymentManager.shared.removePurchase(productID)
            }
        }

        resolveUnfinishedPayment(for: resolveAbleSkus)
    }

    private func resolveUnfinishedPayment(for skus: [String]) {
        var skus = skus
        guard let sku = skus.last,
              let course = environment.interface?.course(fromSKU: sku) else {
            // course not available for sku
            // remove it from the active purchases
            if skus.count > 1 {
                PaymentManager.shared.removePurchase(skus.last ?? "")
                skus.removeLast()
                resolveUnfinishedPayment(for: skus)
            }
            return
        }
        
        guard let courseSku = course.sku, environment.serverConfig.iapConfig?.enabledforUser == true else { return }
        
        PaymentManager.shared.fetchPrroduct(courseSku) { [weak self] product in
            if let product = product {
                self?.upgradeCourse(course: course, localizedCoursePrice: product.localizedPrice, price: product.price, currencyCode: product.priceLocale.currencyCode)
            }
        }
    }
    
    private func upgradeCourse(course: OEXCourse, localizedCoursePrice: String?, price: NSDecimalNumber?, currencyCode: String?) {
        let pacing: String = course.isSelfPaced == true ? "self" : "instructor"
        courseUpgradeHelper.setupHelperData(environment: environment, pacing: pacing, courseID: course.course_id ?? "", localizedCoursePrice: localizedCoursePrice ?? "", screen: .myCourses)
        environment.analytics.trackCourseUnfulfilledPurchaseInitiated(courseID: course.course_id ?? "", pacing: pacing, screen: .myCourses, flowType: CourseUpgradeHandler.CourseUpgradeMode.silent.rawValue)

        let upgradeHandler = CourseUpgradeHandler(for: course, environment: environment)
        upgradeHandler.upgradeCourse(with: .silent, price: price, currencyCode: currencyCode) { [weak self] state in
            switch state {
            case .verify:
                self?.courseUpgradeHelper.handleCourseUpgrade(upgradeHadler: upgradeHandler, state: .fulfillment(showLoader: false))
                break
            case .complete:
                self?.courseUpgradeHelper.handleCourseUpgrade(upgradeHadler: upgradeHandler, state: .success(course.course_id ?? "", nil))
                break
            case .error(let type, let error):
                self?.courseUpgradeHelper.handleCourseUpgrade(upgradeHadler: upgradeHandler, state: .error(type, error))
                break
            default:
                break
            }
        }
    }
}
