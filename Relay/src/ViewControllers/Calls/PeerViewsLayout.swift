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
//    func peerViewDiameter() -> CGFloat
}

class PeerViewsLayout: UICollectionViewLayout {
    
    let margin: CGFloat = 8.0
    
    weak var delegate: PeerViewsLayoutDelegate!
    
    private var attrCache = [UICollectionViewLayoutAttributes]()
    
    override var collectionViewContentSize: CGSize {
        get {
            guard collectionView != nil else { return CGSize() }
            
            let height = self.collectionView!.frame.size.height
            let width = CGFloat(self.collectionView!.numberOfItems(inSection: 0)) * height
            
            return CGSize(width: width, height: height)
        }
    }
    
    override func prepare() {
        
        guard collectionView != nil else {
            return
        }
        
        let totalItems = self.collectionView!.numberOfItems(inSection: 0)

        self.attrCache.removeAll()
        
        // Loop over all objects in collectionView
        for cellIndex in 0 ..< totalItems {

            let indexPath = IndexPath(item: cellIndex, section: 0)
            let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)

            let height = self.collectionViewContentSize.height
            let width = height
            let x: CGFloat = (CGFloat(cellIndex) * height)
            let y: CGFloat = 0.0

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
