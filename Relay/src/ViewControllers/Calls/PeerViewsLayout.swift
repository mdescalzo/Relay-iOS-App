//
//  PeerViewsLayout.swift
//  CallUITestBed
//
//  Created by Mark Descalzo on 1/31/19.
//  Copyright © 2019 Ringneck Software, LLC. All rights reserved.
//

import UIKit
import CoreGraphics

protocol PeerViewsLayoutDelegate: class {
    func containerViewSize() -> CGSize
}

class PeerViewsLayout: UICollectionViewLayout {
    
    let margin: CGFloat = 8.0
    
    weak var delegate: PeerViewsLayoutDelegate!
    
    private var attrCache = [UICollectionViewLayoutAttributes]()
    
    override var collectionViewContentSize: CGSize {
        get {
            guard collectionView != nil else { return CGSize() }
            
            let height = self.delegate.containerViewSize().height
            var width = CGFloat(self.collectionView!.numberOfItems(inSection: 0)) * height
            
            if width < self.delegate.containerViewSize().width {
                width = self.delegate.containerViewSize().width
            }
            
            return CGSize(width: width, height: height)
        }
    }
    
    override func prepare() {
        
        guard collectionView != nil else {
            return
        }
        
        let totalItems = self.collectionView!.numberOfItems(inSection: 0)

        self.attrCache.removeAll()
        
        // Find initial x - we want to center totals less than 4
        let height = self.collectionViewContentSize.height - (2*margin)
        let width = height

        var initialX: CGFloat
        if totalItems < 4 {
            let center = self.delegate.containerViewSize().width/2
            let offset = CGFloat(totalItems)/2 * (height+margin)
            initialX = center - offset
        } else {
            initialX = margin
        }
        // Loop over all objects in collectionView
        for cellIndex in 0 ..< totalItems {

            let indexPath = IndexPath(item: cellIndex, section: 0)
            let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)

            let x: CGFloat = initialX + (CGFloat(cellIndex) * (height+margin))
            let y: CGFloat = margin

            let frame = CGRect(x: x, y: y, width: width, height: height)
            
            attributes.frame = frame
            
            // Store the attributes in the local cache objects
            attrCache.append(attributes)
        }
    }
    
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        return attrCache[indexPath.item]
    }
    
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var visibleLayoutAttributes = [UICollectionViewLayoutAttributes]()
        
        // Loop through the cache and look for items in the rect
        for attributes in attrCache {
            if attributes.frame.intersects(rect) {
                visibleLayoutAttributes.append(attributes)
            }
        }
        return visibleLayoutAttributes
    }
    
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        return super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }
    
    override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        return super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)
    }
    
    override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        return super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath)
    }
}
